//! roc:subprocess host (seahaven's design, P3): spawn via std::process::Command.
//! The crossing record carries the `OsStr` nominal; Utf8 is what Roc mints
//! here, UnixBytes is honored raw. Owned-argument rule (B0): the whole command
//! record is owned and released via its own decref (recurses into args/envs
//! element strings), not field-by-field.
//!
//! `spawn` is the only way a process starts. The four run-to-completion calls
//! each built their own `Command`, so a fix such as the signal-mask reset had
//! four places to land; `Cmd` runs them over `spawn!` now (D-S2-13).
use core::mem::ManuallyDrop;
use trantor_abi as abi;
use abi::*;
use std::ffi::{OsStr, OsString};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::process::CommandExt;
use std::process::Command;

mod spawn;

/// The ROC `OsStr`, qualified: `std::ffi::OsStr` is imported above and would
/// otherwise win the name.
pub(crate) type Native = abi::OsStr;

// The userland cwd lives in the `cwd-host` component (FsOps.set_cwd! writes it);
// read it to run subprocesses in that directory (Option A cwd model).
unsafe extern "C-unwind" {
    fn trantor__cwd_host__get() -> RocStr;
}

pub(crate) fn to_os(n: &Native) -> OsString {
    unsafe {
        match n.tag {
            OsStrTag::Utf8 => OsString::from((*n.payload.utf8).as_str()),
            OsStrTag::UnixBytes => OsStr::from_bytes((*n.payload.unix_bytes).as_slice()).to_os_string(),
            OsStrTag::WindowsU16s => OsString::from(String::from_utf16_lossy((*n.payload.windows_u16s).as_slice())),
        }
    }
}

/// `Subprocess.Cmd`; its glue name is a hash of the record shape.
pub(crate) type CmdRecord = AnonStructA666ca78571ad967;

/// Build the Command and release the owned record (B0 rule).
pub(crate) fn command(a: CmdRecord) -> Command {
    let mut c = Command::new(to_os(&a.program));
    c.args(a.args.as_slice().iter().map(to_os));
    if a.clear_envs { c.env_clear(); }
    let envs: Vec<OsString> = a.envs.as_slice().iter().map(to_os).collect();
    for kv in envs.chunks(2) { if let [k, v] = kv { c.env(k, v); } }
    unsafe { a.decref(abi::host()); } // whole-struct decref recurses into args/envs elements (B0)
    // Honor the userland cwd so a child runs where file ops resolve (basic-cli's
    // observable single-cwd behavior), without mutating this process's real cwd.
    // Empty = no set_cwd! yet = inherit the process cwd.
    let cwd = userland_cwd();
    if !cwd.is_empty() { c.current_dir(cwd); }
    // SAFETY: the hook makes only async-signal-safe calls between fork and exec.
    unsafe { c.pre_exec(clear_signal_mask); }
    c
}

/// The userland cwd; empty until `Env.set_cwd!`.
fn userland_cwd() -> String {
    let cwd = unsafe { trantor__cwd_host__get() };
    let owned = cwd.as_str().to_string();
    unsafe { cwd.decref(abi::host()); }
    owned
}

/// Whether this user may execute `path`, as `exec` would decide, following
/// links. A relative path is resolved against the userland cwd.
pub(crate) fn executable_by_user(path: &[u8]) -> std::io::Result<()> {
    let relative = std::path::Path::new(OsStr::from_bytes(path));
    let cwd = userland_cwd();
    let full = if relative.is_absolute() || cwd.is_empty() { relative.to_path_buf() } else { std::path::Path::new(&cwd).join(relative) };
    let c_path = std::ffi::CString::new(full.as_os_str().as_bytes()).map_err(|_| std::io::Error::new(std::io::ErrorKind::InvalidInput, "a path holding a NUL byte"))?;
    // SAFETY: a NUL-terminated path; AT_EACCESS checks with the effective ids.
    if unsafe { libc::faccessat(libc::AT_FDCWD, c_path.as_ptr(), libc::X_OK, libc::AT_EACCESS) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    // `access` answers on the mode bits alone, so an executable FIFO or device
    // passes it; `execve` refuses anything but a regular file with EACCES.
    if std::fs::metadata(&full)?.is_file() {
        Ok(())
    } else {
        Err(std::io::Error::from_raw_os_error(libc::EACCES))
    }
}

/// A spawn whose working directory was removed after `Env.set_cwd!` fails in
/// chdir with `NotFound`, which reads exactly like a missing program. Named
/// here instead, so a caller matching `NotFound` does not decide the tool is
/// not installed.
pub(crate) fn explain_missing_cwd(e: std::io::Error) -> std::io::Error {
    let cwd = userland_cwd();
    if e.kind() == std::io::ErrorKind::NotFound && !cwd.is_empty() && !std::path::Path::new(&cwd).is_dir() {
        std::io::Error::other(format!("the working directory {cwd} no longer exists"))
    } else {
        e
    }
}

/// A child starts with no signals blocked. std hands it the parent's mask, and
/// a host may block a signal on the app's thread for its own reasons:
/// trantor-terminal blocks SIGWINCH there so a resize reaches only its own
/// thread (trantor D-K1-29), and vim started under that mask would never see a
/// resize. A Roc app cannot block a signal itself, so none of it is the child's.
fn clear_signal_mask() -> std::io::Result<()> {
    // SAFETY: plain libc calls on a stack-local set, in the single-threaded child.
    let failed = unsafe {
        let mut none: libc::sigset_t = core::mem::zeroed();
        libc::sigemptyset(&mut none) != 0 || libc::sigprocmask(libc::SIG_SETMASK, &none, core::ptr::null_mut()) != 0
    };
    if failed { Err(std::io::Error::last_os_error()) } else { Ok(()) }
}
/// Glue emits one structurally identical `IOErr` per reach path and names
/// them by which leaf it met first: the raw spawn's is `SubprocessRawIOErr`,
/// `handle_wait!`'s is `SubprocessIOErr`, and the rest meet the plain `IOErr`. Same ten variants, same mapping.
macro_rules! ioerr_ctor {
    ($name:ident, $ty:ident, $pl:ident, $tag:ident) => {
        pub(crate) fn $name(e: &std::io::Error) -> $ty {
            let tag = sync_io_core::ioerr_tag!(e, $tag);
            if let $tag::Other = tag {
                $ty { payload: $pl { other: ManuallyDrop::new(RocStr::from_str(&e.to_string(), abi::host())) }, tag }
            } else {
                $ty { payload: unsafe { core::mem::zeroed() }, tag }
            }
        }
    };
}
ioerr_ctor!(ioerr, IOErr, IOErrPayload, IOErrTag);
ioerr_ctor!(wait_ioerr, SubprocessIOErr, SubprocessIOErrPayload, SubprocessIOErrTag);
ioerr_ctor!(spawn_ioerr, SubprocessRawIOErr, SubprocessRawIOErrPayload, SubprocessRawIOErrTag);
