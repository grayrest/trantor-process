//! `Subprocess.spawn!` and the `Child` operations: a child as a resource whose
//! pipes are sync-io streams minted once at spawn.
use core::mem::ManuallyDrop;
use core::sync::atomic::{AtomicIsize, Ordering};
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::process::ExitStatusExt;
use std::process::{Child, Stdio};
use sync_io_core::{Handoff, Input, Output};
use trantor_abi as abi;
use abi::*;

type Redirect = FdOrInheritOrNullOrPipe;
type Redirects = AnonStruct5a3e995f7b1c3c4f;
type Collected = AnonStructD5b8683e647eaa92;
type Signal = HupOrIntOrKillOrQuitOrTermOrUsr1OrUsr2;

/// The `Handle` resource. Each pipe is held as the stream resource Roc is
/// given, so every `stdout!` call returns the same stream and bytes buffered by
/// one read are there for the next — a stream minted per call would drop them.
struct Spawned {
    child: Child,
    stdin: Option<RocBox>,
    stdout: Option<RocBox>,
    stderr: Option<RocBox>,
}

impl Drop for Spawned {
    /// Releases this handle's reference to each pipe. The child is neither
    /// killed nor reaped: `Child` does neither on drop.
    fn drop(&mut self) {
        for pipe in [self.stdin, self.stdout, self.stderr].into_iter().flatten() {
            // SAFETY: each box was minted at spawn and this is its handle's reference.
            unsafe { abi::resource::release(pipe) };
        }
    }
}

/// Another reference to a stream resource, for Roc to own.
fn share(b: RocBox) -> RocBox {
    // SAFETY: a live resource box; its refcount word sits 8 bytes before the data.
    let rc = unsafe { (b as *mut u8).sub(8) } as *mut AtomicIsize;
    if unsafe { (*rc).load(Ordering::Relaxed) } != 0 {
        unsafe { (*rc).fetch_add(1, Ordering::Relaxed) };
    }
    b
}

/// The child's stdin. A write to a pipe whose reader has exited raises SIGPIPE,
/// whose default kills the app: the generated driver's `main` is exported to
/// C, so Rust's startup never ignores it, and trantor keeps the default on
/// purpose so pipelines end quietly. Only this write must answer `BrokenPipe`
/// instead, so only this write suppresses the signal (D-S2-26); the app, its
/// stdout and every child keep the default.
struct PipeWriter(std::process::ChildStdin);
impl Write for PipeWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let fd = self.0.as_raw_fd();
        without_sigpipe(fd, || self.0.write(buf))
    }
    fn flush(&mut self) -> std::io::Result<()> { self.0.flush() }
}

/// macOS sends a pipe write's SIGPIPE to the process, so blocking it on the
/// thread does not stop it; the pipe can be told not to raise it. The flag
/// belongs to the open file, which a child handed the pipe through `ToStream`
/// shares, so it is set for this write only: left on, that child never got its
/// SIGPIPE (`yes` feeding `head -c 1` exited 1 instead of dying).
#[cfg(target_vendor = "apple")]
fn without_sigpipe<T>(fd: std::os::fd::RawFd, write: impl FnOnce() -> std::io::Result<T>) -> std::io::Result<T> {
    /// `<sys/fcntl.h>`'s F_SETNOSIGPIPE, which the libc crate does not define.
    const F_SETNOSIGPIPE: libc::c_int = 73;
    // SAFETY: fcntl on the stdin pipe this handle owns.
    unsafe { libc::fcntl(fd, F_SETNOSIGPIPE, 1) };
    let result = write();
    unsafe { libc::fcntl(fd, F_SETNOSIGPIPE, 0) };
    result
}

/// Linux sends a write's SIGPIPE to the writing thread: block it for the
/// write, and take the one this write raised before restoring the mask.
///
/// Whatever the write returned: a blocked write whose reader exits partway
/// returns the bytes it copied AND raises SIGPIPE, so taking it only on
/// `BrokenPipe` let the partial write's signal kill the app at the restore.
/// A SIGPIPE already pending before the write is not this write's, and is
/// left for the mask to deliver.
#[cfg(not(target_vendor = "apple"))]
fn without_sigpipe<T>(_fd: std::os::fd::RawFd, write: impl FnOnce() -> std::io::Result<T>) -> std::io::Result<T> {
    // SAFETY: signal-mask calls on stack-local sets for the calling thread only.
    unsafe {
        let mut sigpipe: libc::sigset_t = core::mem::zeroed();
        libc::sigemptyset(&mut sigpipe);
        libc::sigaddset(&mut sigpipe, libc::SIGPIPE);
        let mut previous: libc::sigset_t = core::mem::zeroed();
        libc::pthread_sigmask(libc::SIG_BLOCK, &sigpipe, &mut previous);
        let was_blocked = libc::sigismember(&previous, libc::SIGPIPE) == 1;
        let pending_before = sigpipe_pending();
        let result = write();
        if !was_blocked && !pending_before && sigpipe_pending() {
            // A zero timeout: never waits, even if another thread took it first.
            let no_wait = libc::timespec { tv_sec: 0, tv_nsec: 0 };
            libc::sigtimedwait(&sigpipe, core::ptr::null_mut(), &no_wait);
        }
        libc::pthread_sigmask(libc::SIG_SETMASK, &previous, core::ptr::null_mut());
        result
    }
}

#[cfg(not(target_vendor = "apple"))]
fn sigpipe_pending() -> bool {
    // SAFETY: sigpending fills a stack-local set.
    unsafe {
        let mut pending: libc::sigset_t = core::mem::zeroed();
        libc::sigpending(&mut pending);
        libc::sigismember(&pending, libc::SIGPIPE) == 1
    }
}

/// What a closed stdin pipe becomes, so a stream Roc still holds reports the
/// close instead of writing into nothing.
struct Closed;
impl Write for Closed {
    fn write(&mut self, _: &[u8]) -> std::io::Result<usize> {
        Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "the child's stdin was closed"))
    }
    fn flush(&mut self) -> std::io::Result<()> { Ok(()) }
}

fn close_stdin(s: &Spawned) {
    if let Some(b) = s.stdin {
        // SAFETY: minted at spawn as an Output; Roc is blocked in this call.
        let out = unsafe { abi::resource::get::<Output>(b) };
        out.0 = Box::new(Closed);
        out.1 = Handoff::NotAFile;
    }
}

/// The child's copy of a redirect. An `Fd` is borrowed: duplicated here, and
/// the caller closes its own. Taking ownership let any number an app passed be
/// closed after the spawn, its stdout included.
fn stdio(r: Redirect) -> std::io::Result<Stdio> {
    Ok(match r.tag {
        FdOrInheritOrNullOrPipeTag::Fd => {
            let fd = unsafe { *r.payload.fd };
            // SAFETY: F_DUPFD_CLOEXEC makes a new descriptor, owned from here.
            let copy = unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, FIRST_NON_STDIO_FD) };
            if copy < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Stdio::from(unsafe { OwnedFd::from_raw_fd(copy) })
        }
        FdOrInheritOrNullOrPipeTag::Inherit => Stdio::inherit(),
        FdOrInheritOrNullOrPipeTag::Null => Stdio::null(),
        FdOrInheritOrNullOrPipeTag::Pipe => Stdio::piped(),
    })
}

/// The lowest fd a duplicate may take, as `FdHandoff`'s: with a standard stream
/// closed, a copy numbered 0-2 could be closed while the child's stdio is set up.
const FIRST_NON_STDIO_FD: i32 = 3;

fn exit_status(st: std::process::ExitStatus) -> ExitedOrSignaled {
    match st.code() {
        Some(code) => ExitedOrSignaled { payload: ExitedOrSignaledPayload { exited: ManuallyDrop::new(code) }, tag: ExitedOrSignaledTag::Exited },
        None => ExitedOrSignaled { payload: ExitedOrSignaledPayload { signaled: ManuallyDrop::new(st.signal().unwrap_or(0)) }, tag: ExitedOrSignaledTag::Signaled },
    }
}

fn with<R>(h: *mut u64, f: impl FnOnce(&mut Spawned) -> R) -> R {
    // SAFETY: a Handle is only ever minted by `spawn_redirected` below.
    unsafe { abi::resource::with(h as RocBox, f) }
}

#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__subprocess_host__spawn_redirected(cmd: crate::CmdRecord, r: Redirects) -> SubprocessRawSpawnRedirectedResult {
    let streams = stdio(r.stdin).and_then(|i| Ok((i, stdio(r.stdout)?, stdio(r.stderr)?)));
    // Built even when a copy failed, so the owned record is released.
    let mut c = crate::command(cmd);
    let started = streams.and_then(|(stdin, stdout, stderr)| {
        c.stdin(stdin).stdout(stdout).stderr(stderr);
        c.spawn().map_err(crate::explain_missing_cwd)
    });
    match started {
        Ok(mut child) => {
            let stdin = child.stdin.take().map(|p| { let fd = p.as_raw_fd(); sync_io_core::output_stream_fd(Box::new(PipeWriter(p)), fd) });
            let stdout = child.stdout.take().map(|p| { let fd = p.as_raw_fd(); sync_io_core::input_stream_fd(Box::new(p), fd) });
            let stderr = child.stderr.take().map(|p| { let fd = p.as_raw_fd(); sync_io_core::input_stream_fd(Box::new(p), fd) });
            let handle = abi::resource::new(Spawned { child, stdin, stdout, stderr }) as *mut u64;
            SubprocessRawSpawnRedirectedResult { payload: SubprocessRawSpawnRedirectedResultPayload { ok: ManuallyDrop::new(handle) }, tag: SubprocessRawSpawnRedirectedResultTag::Ok }
        }
        Err(e) => SubprocessRawSpawnRedirectedResult { payload: SubprocessRawSpawnRedirectedResultPayload { err: ManuallyDrop::new(crate::spawn_ioerr(&e)) }, tag: SubprocessRawSpawnRedirectedResultTag::Err },
    }
}

#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__subprocess_host__handle_pid(h: *mut u64) -> i32 {
    with(h, |s| s.child.id() as i32)
}

/// `pipe` is already shared: taken inside the handle's borrow, because the
/// borrow's release can drop the handle and, with it, its reference to the pipe.
fn piped_out(pipe: Option<RocBox>) -> SubprocessHandleStdinResult {
    match pipe {
        Some(b) => SubprocessHandleStdinResult { payload: SubprocessHandleStdinResultPayload { ok: ManuallyDrop::new(b as *mut u64) }, tag: SubprocessHandleStdinResultTag::Ok },
        None => SubprocessHandleStdinResult { payload: SubprocessHandleStdinResultPayload { err: [] }, tag: SubprocessHandleStdinResultTag::Err },
    }
}
fn piped_in(pipe: Option<RocBox>) -> SubprocessHandleStdoutResult {
    match pipe {
        Some(b) => SubprocessHandleStdoutResult { payload: SubprocessHandleStdoutResultPayload { ok: ManuallyDrop::new(b as *mut u64) }, tag: SubprocessHandleStdoutResultTag::Ok },
        None => SubprocessHandleStdoutResult { payload: SubprocessHandleStdoutResultPayload { err: [] }, tag: SubprocessHandleStdoutResultTag::Err },
    }
}

#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__subprocess_host__handle_stdin(h: *mut u64) -> SubprocessHandleStdinResult { piped_out(with(h, |s| s.stdin.map(share))) }
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__subprocess_host__handle_stdout(h: *mut u64) -> SubprocessHandleStdoutResult { piped_in(with(h, |s| s.stdout.map(share))) }
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__subprocess_host__handle_stderr(h: *mut u64) -> SubprocessHandleStdoutResult { piped_in(with(h, |s| s.stderr.map(share))) }
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__subprocess_host__handle_close_stdin(h: *mut u64) { with(h, |s| close_stdin(s)) }

/// Closes stdin first, as `std::process::Child::wait` does, so a child
/// reading to end of input can finish.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__subprocess_host__handle_wait(h: *mut u64) -> SubprocessHandleWaitResult {
    match with(h, |s| { close_stdin(s); s.child.wait() }) {
        Ok(st) => SubprocessHandleWaitResult { payload: SubprocessHandleWaitResultPayload { ok: ManuallyDrop::new(exit_status(st)) }, tag: SubprocessHandleWaitResultTag::Ok },
        Err(e) => SubprocessHandleWaitResult { payload: SubprocessHandleWaitResultPayload { err: ManuallyDrop::new(crate::wait_ioerr(&e)) }, tag: SubprocessHandleWaitResultTag::Err },
    }
}

#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__subprocess_host__handle_try_wait(h: *mut u64) -> SubprocessHandleTryWaitResult {
    match with(h, |s| s.child.try_wait()) {
        Ok(Some(st)) => SubprocessHandleTryWaitResult { payload: SubprocessHandleTryWaitResultPayload { ok: ManuallyDrop::new(DoneOrRunning { payload: DoneOrRunningPayload { done: ManuallyDrop::new(exit_status(st)) }, tag: DoneOrRunningTag::Done }) }, tag: SubprocessHandleTryWaitResultTag::Ok },
        Ok(None) => SubprocessHandleTryWaitResult { payload: SubprocessHandleTryWaitResultPayload { ok: ManuallyDrop::new(DoneOrRunning { payload: DoneOrRunningPayload { running: [] }, tag: DoneOrRunningTag::Running }) }, tag: SubprocessHandleTryWaitResultTag::Ok },
        Err(e) => SubprocessHandleTryWaitResult { payload: SubprocessHandleTryWaitResultPayload { err: ManuallyDrop::new(crate::ioerr(&e)) }, tag: SubprocessHandleTryWaitResultTag::Err },
    }
}

/// Signals only a child not yet reaped. Once `wait!` or `try_wait!` has
/// reaped it, its pid is free for the OS to hand to an unrelated process, so a
/// later `kill` could signal that one. `try_wait` here reaps an exited child
/// first, and an unreaped child's pid cannot be reused. The error is read
/// inside the borrow, before a release that drops the handle can change errno.
fn send(s: &mut Spawned, number: libc::c_int) -> std::io::Result<()> {
    if s.child.try_wait()?.is_some() {
        return Err(std::io::Error::from_raw_os_error(libc::ESRCH));
    }
    // SAFETY: kill(2) on this unreaped child's pid.
    if unsafe { libc::kill(s.child.id() as libc::pid_t, number) } == 0 { Ok(()) } else { Err(std::io::Error::last_os_error()) }
}

#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__subprocess_host__handle_signal(h: *mut u64, sig: Signal) -> SubprocessHandleSignalResult {
    let number = match sig {
        Signal::Hup => libc::SIGHUP,
        Signal::Int => libc::SIGINT,
        Signal::Kill => libc::SIGKILL,
        Signal::Quit => libc::SIGQUIT,
        Signal::Term => libc::SIGTERM,
        Signal::Usr1 => libc::SIGUSR1,
        Signal::Usr2 => libc::SIGUSR2,
    };
    match with(h, |s| send(s, number)) {
        Ok(()) => SubprocessHandleSignalResult { payload: SubprocessHandleSignalResultPayload { ok: [] }, tag: SubprocessHandleSignalResultTag::Ok },
        Err(e) => SubprocessHandleSignalResult { payload: SubprocessHandleSignalResultPayload { err: ManuallyDrop::new(crate::ioerr(&e)) }, tag: SubprocessHandleSignalResultTag::Err },
    }
}

/// A stream backing, lent to one scoped thread while the Roc caller is blocked
/// in `collect!`.
struct Lent<T>(*mut T);
// SAFETY: the pipe behind each backing is an OS fd, safe to use from another
// thread; each backing is lent to exactly one thread, and the scope joins it
// before the resource can be touched again.
unsafe impl<T> Send for Lent<T> {}

fn lend<T>(b: Option<RocBox>) -> Option<Lent<T>> {
    // SAFETY: minted at spawn with backing type T.
    b.map(|b| Lent(unsafe { abi::resource::get::<T>(b) } as *mut T))
}

fn read_to_end(lent: Option<Lent<Input>>) -> std::io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    if let Some(Lent(input)) = lent {
        // SAFETY: see `Lent`.
        unsafe { &mut *input }.0.read_to_end(&mut bytes)?;
    }
    Ok(bytes)
}

fn collect(s: &mut Spawned, input: &[u8]) -> Result<Collected, IoOrNotPiped> {
    let io = |e: std::io::Error| IoOrNotPiped { payload: IoOrNotPipedPayload { io: ManuallyDrop::new(crate::ioerr(&e)) }, tag: IoOrNotPipedTag::Io };
    // SAFETY: minted at spawn as an Output. A closed stdin has no fd.
    let stdin_open = s.stdin.is_some_and(|b| matches!(unsafe { abi::resource::get::<Output>(b) }.1, Handoff::Fd(_)));
    if !stdin_open && !input.is_empty() {
        return Err(IoOrNotPiped { payload: IoOrNotPipedPayload { not_piped: [] }, tag: IoOrNotPipedTag::NotPiped });
    }
    // Already reaped (by `try_wait!` before this call), its pid may be someone
    // else's, so a failed read kills nothing.
    let pid = match s.child.try_wait() {
        Ok(None) => Some(s.child.id() as libc::pid_t),
        _ => None,
    };
    let (stdin, stdout, stderr) = (lend::<Output>(s.stdin), lend::<Input>(s.stdout), lend::<Input>(s.stderr));
    let (out, err) = std::thread::scope(|scope| {
        // Builder, not `scope.spawn`, which panics when no thread can be made
        // and took the app down through the driver's catch_unwind.
        let writer = std::thread::Builder::new().spawn_scoped(scope, move || {
            if let Some(Lent(output)) = stdin {
                // SAFETY: see `Lent`.
                let output = unsafe { &mut *output };
                // A child that exits without reading all of its input is not a
                // collect failure; its status says what happened.
                let _ = output.0.write_all(input);
                output.0 = Box::new(Closed);
                output.1 = Handoff::NotAFile;
            }
        });
        let writer = match writer {
            Ok(w) => w,
            // Nothing will drain the child's output, and its stdin stays open:
            // a caller following the doc and waiting would wait forever.
            Err(e) => {
                kill_unreaped(pid);
                return (Err(e), Ok(Vec::new()));
            }
        };
        let out = match std::thread::Builder::new().spawn_scoped(scope, move || stop_on_failure(read_to_end(stdout), pid)) {
            Ok(t) => t,
            Err(e) => {
                // The writer may be blocked on a child that will not read.
                kill_unreaped(pid);
                let _ = writer.join();
                return (Err(e), Ok(Vec::new()));
            }
        };
        let err = stop_on_failure(read_to_end(stderr), pid);
        let _ = writer.join();
        // A panic in either thread is not recoverable here: `thread::scope`
        // re-panics for any scoped thread that panicked, joined or not, so it
        // reaches the driver's catch_unwind rather than this result.
        (out.join().unwrap_or_else(|_| Err(std::io::Error::other("the stdout reader panicked"))), err)
    });
    let (stdout, stderr) = (out.map_err(io)?, err.map_err(io)?);
    let status = s.child.wait().map_err(io)?;
    // One output in memory twice at a time, not both: each buffer goes as soon
    // as Roc's copy of it exists.
    // SAFETY: fresh lists handed to Roc, which owns them.
    let stdout_list = unsafe { RocListWith::<u8, false>::from_slice(&stdout, abi::host()) };
    drop(stdout);
    let stderr_list = unsafe { RocListWith::<u8, false>::from_slice(&stderr, abi::host()) };
    drop(stderr);
    Ok(Collected { stdout: stdout_list, stderr: stderr_list, status: exit_status(status) })
}

/// A reader that fails leaves the other output unread; a child blocked writing
/// that full pipe would keep the other reader, and the join, waiting forever.
/// Killing it ends the other pipe. `pid` is `Some` only for a child unreaped
/// when `collect` began, and nothing reaps it before `collect` returns, so it
/// cannot belong to anyone else yet.
fn stop_on_failure(read: std::io::Result<Vec<u8>>, pid: Option<libc::pid_t>) -> std::io::Result<Vec<u8>> {
    if read.is_err() {
        kill_unreaped(pid);
    }
    read
}

fn kill_unreaped(pid: Option<libc::pid_t>) {
    if let Some(pid) = pid {
        // SAFETY: kill(2) on this call's unreaped child.
        unsafe { libc::kill(pid, libc::SIGKILL) };
    }
}

/// `Subprocess.can_execute!`: `faccessat(X_OK, AT_EACCESS)`, a relative path
/// against the userland cwd as a spawn resolves it.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__subprocess_host__can_execute(path: crate::Native) -> SubprocessCanExecuteResult {
    let native = crate::to_os(&path);
    // SAFETY: owned argument (B0).
    unsafe { path.decref(abi::host()) };
    match crate::executable_by_user(native.as_bytes()) {
        Ok(()) => SubprocessCanExecuteResult { payload: SubprocessCanExecuteResultPayload { ok: [] }, tag: SubprocessCanExecuteResultTag::Ok },
        Err(e) => SubprocessCanExecuteResult { payload: SubprocessCanExecuteResultPayload { err: ManuallyDrop::new(crate::ioerr(&e)) }, tag: SubprocessCanExecuteResultTag::Err },
    }
}

#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__subprocess_host__handle_collect(h: *mut u64, input: RocListWith<u8, false>) -> SubprocessHandleCollectResult {
    // Borrowed for the call and released after, not copied first: the input
    // can be as large as the outputs.
    let collected = with(h, |s| collect(s, input.as_slice()));
    // SAFETY: owned list argument (B0), no longer borrowed.
    unsafe { input.decref(abi::host()) };
    match collected {
        Ok(c) => SubprocessHandleCollectResult { payload: SubprocessHandleCollectResultPayload { ok: ManuallyDrop::new(c) }, tag: SubprocessHandleCollectResultTag::Ok },
        Err(e) => SubprocessHandleCollectResult { payload: SubprocessHandleCollectResultPayload { err: ManuallyDrop::new(e) }, tag: SubprocessHandleCollectResultTag::Err },
    }
}
