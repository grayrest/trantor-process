import IOErr exposing [IOErr]
import OsStr exposing [OsStr]
import Cwd
import Fs
import Streams
import FdHandoff
import SubprocessRaw
## roc:subprocess (roc-native, P3; seahaven's design): one way to start a
## process, `spawn!`, and the operations on the `Child` it returns. The command
## record keeps seahaven's OsStr union so Cmd.roc's PATH-split ports verbatim;
## the host honors Utf8 and UnixBytes raw.
##
## A spawned child is not confined by the filesystem policy: it can open any
## path the OS lets it.
Subprocess :: [].{
	## What to run: the program, its arguments, and `envs` as a flat list of
	## key and value, one after the other. `clear_envs` starts the child with
	## only those; otherwise they are added to this process's environment.
	Cmd : SubprocessRaw.Cmd
	## What `Cmd`'s capturing functions answer.
	CmdOutputSuccess : { stderr_bytes : List(U8), stdout_bytes : List(U8) }
	CmdOutputFailure : { stderr_bytes : List(U8), stdout_bytes : List(U8), exit_code : I32 }

	## Where one of a child's standard streams goes. `Descriptor` redirects to
	## or from an open file with no shell; giving stdout and stderr the same
	## descriptor merges them. `ToStream` sends an output to a stream that has
	## a file under it (a file writer, this process's stdout or stderr).
	Stdio : [Inherit, Null, Pipe, Descriptor(Fs.Descriptor), ToStream(Streams.OutputStream)]
	## How a child ended: its exit code, or the signal that killed it.
	ExitStatus : [Exited(I32), Signaled(I32)]
	Signal : [Term, Kill, Int, Hup, Quit, Usr1, Usr2]
	## The host's handle on a child; `SubprocessRaw` mints it.
	Handle : SubprocessRaw.Handle

	handle_pid! : Handle => I32
	handle_stdin! : Handle => Try(Streams.OutputStream, [NotPiped])
	handle_stdout! : Handle => Try(Streams.InputStream, [NotPiped])
	handle_stderr! : Handle => Try(Streams.InputStream, [NotPiped])
	handle_close_stdin! : Handle => {}
	handle_wait! : Handle => Try(ExitStatus, [Io(IOErr)])
	handle_try_wait! : Handle => Try([Running, Done(ExitStatus)], [Io(IOErr)])
	handle_signal! : Handle, Signal => Try({}, [Io(IOErr)])
	## Whether this user may execute `path` (resolved against the userland cwd),
	## following links, as `exec` decides: `access(X_OK)` with the effective
	## ids. An execute bit for another user, or a file on a `noexec` mount, is
	## `PermissionDenied`. Not confined, as a spawn is not.
	can_execute! : OsStr => Try({}, [Io(IOErr)])
	can_execute! = |path| SubprocessRaw.can_execute!(path, Cwd.get!({}))
	handle_collect! : Handle, List(U8) => Try({ status : ExitStatus, stdout : List(U8), stderr : List(U8) }, [Io(IOErr), NotPiped])

	## A started child process.
	Child :: { handle : Handle, pid : I32 }.{
		pid : Child -> I32
		pid = |child| child.pid
		## The pipe to the child's stdin; `NotPiped` unless spawned with `Pipe`.
		## Every call returns the same stream.
		stdin! : Child => Try(Streams.OutputStream, [NotPiped])
		stdin! = |child| match Subprocess.handle_stdin!(child.handle) {
			Ok(s) => Ok(s)
			Err(NotPiped) => Err(NotPiped)
		}
		## The pipe from the child's stdout. Every call returns the same stream,
		## so bytes one read buffered are there for the next.
		##
		## Reading stdout to its end while the child blocks writing a full
		## stderr pipe (about 64 KB) deadlocks both. Read both on the same
		## schedule, or use `collect!`.
		stdout! : Child => Try(Streams.InputStream, [NotPiped])
		stdout! = |child| input(Subprocess.handle_stdout!(child.handle))
		stderr! : Child => Try(Streams.InputStream, [NotPiped])
		stderr! = |child| input(Subprocess.handle_stderr!(child.handle))
		## Close the pipe to stdin, so a child reading it sees end of input.
		close_stdin! : Child => {}
		close_stdin! = |child| Subprocess.handle_close_stdin!(child.handle)
		## Close stdin, then wait for the child to end. A child writing more
		## than a pipe holds to a piped stdout or stderr nobody reads never
		## ends, so this never returns: read them, or use `collect!`.
		wait! : Child => Try(ExitStatus, [Io(IOErr)])
		wait! = |child| io(Subprocess.handle_wait!(child.handle))
		## Whether the child has ended, without waiting. Unlike `wait!` this does
		## not close stdin, so a child reading its stdin pipe to the end stays
		## `Running` for good: `close_stdin!` first, or poll until you are ready
		## to `wait!`.
		try_wait! : Child => Try([Running, Done(ExitStatus)], [Io(IOErr)])
		try_wait! = |child| io(Subprocess.handle_try_wait!(child.handle))
		## An already-reaped child is not signalled (its pid may belong to
		## another process by now): `Io(Other("No such process…"))`.
		signal! : Child, Signal => Try({}, [Io(IOErr)])
		signal! = |child, sig| io(Subprocess.handle_signal!(child.handle, sig))
		## Write `input` to stdin and close it, read stdout and stderr to their
		## ends on separate threads, then wait. A grandchild still holding an
		## output pipe keeps this waiting, and so does one holding stdin while
		## input is left unwritten. After an `Io` error the child may have been
		## sent SIGKILL and is not reaped either way: `wait!` it. Input with stdin not piped, or
		## already closed, is `NotPiped`; an output not piped, or already read from, comes back
		## with what was left in it.
		collect! : Child, List(U8) => Try({ status : ExitStatus, stdout : List(U8), stderr : List(U8) }, [Io(IOErr), NotPiped])
		collect! = |child, bytes| match Subprocess.handle_collect!(child.handle, bytes) {
			Ok(done) => Ok(done)
			Err(Io(e)) => Err(Io(e))
			Err(NotPiped) => Err(NotPiped)
		}
	}

	## Start `cmd` with each standard stream as given; all default to `Inherit`.
	## The child starts in the userland cwd with no signals blocked.
	spawn! : Cmd, { stdin ?: Stdio, stdout ?: Stdio, stderr ?: Stdio } => Try(Child, [Io(IOErr)])
	spawn! = |cmd, opts| {
		stdin = redirect!(opts.?stdin ?? Inherit)
		stdout = redirect!(opts.?stdout ?? Inherit)
		stderr = redirect!(opts.?stderr ?? Inherit)
		match (stdin, stdout, stderr) {
			(Ok(i), Ok(o), Ok(e)) => {
				# Read here, not in the host: the wiring for `cwd` is only
				# visible from Roc. Per call, because `Env.set_cwd!` can have
				# moved it since the last spawn.
				spawned = SubprocessRaw.spawn_redirected!(cmd, { stdin: i, stdout: o, stderr: e }, Cwd.get!({}))
				# The host duplicated them for the child; these are still ours.
				release!(stdin)
				release!(stdout)
				release!(stderr)
				match spawned {
					Ok(handle) => Ok(Child.{ handle, pid: Subprocess.handle_pid!(handle) })
					Err(Io(err)) => Err(Io(err))
				}
			}
			_ => {
				# One redirect failed: give back the fds the others took.
				release!(stdin)
				release!(stdout)
				release!(stderr)
				Err(Io(first_failure([stdin, stdout, stderr])))
			}
		}
	}
}

## Not members of `Subprocess`, so an app cannot reach them: `release!` closes
## any fd number it is given.
redirect! : Subprocess.Stdio => Try(SubprocessRaw.Redirect, [NotAFile, Io(IOErr)])
redirect! = |stdio| match stdio {
	Inherit => Ok(Inherit)
	Null => Ok(Null)
	Pipe => Ok(Pipe)
	Descriptor(d) => FdHandoff.descriptor_fd!(d).map_ok(|fd| Fd(fd))
	ToStream(s) => FdHandoff.output_fd!(s).map_ok(|fd| Fd(fd))
}

release! : Try(SubprocessRaw.Redirect, [NotAFile, Io(IOErr)]) => {}
release! = |r| match r {
	Ok(Fd(fd)) => FdHandoff.close_fd!(fd)
	_ => {}
}

## The first redirect's failure, as spawn's error: a stream with no file under
## it is named, and running out of fds keeps its own error.
first_failure : List(Try(SubprocessRaw.Redirect, [NotAFile, Io(IOErr)])) -> IOErr
first_failure = |redirects| match redirects {
	[Err(NotAFile), ..] => Other("a Descriptor or ToStream redirect has no file descriptor under it")
	[Err(Io(e)), ..] => e
	[_, .. as rest] => first_failure(rest)
	[] => Other("a redirect failed")
}

## The raw leaves answer closed unions, which `?` cannot widen into a caller's
## open one; the `Child` methods reopen them.
io : Try(a, [Io(IOErr)]) -> Try(a, [Io(IOErr)])
io = |r| match r {
	Ok(v) => Ok(v)
	Err(Io(e)) => Err(Io(e))
}

input : Try(Streams.InputStream, [NotPiped]) -> Try(Streams.InputStream, [NotPiped])
input = |r| match r {
	Ok(s) => Ok(s)
	Err(NotPiped) => Err(NotPiped)
}
