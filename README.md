# trantor-process

Starting child processes, for [trantor-cli](../trantor-cli) apps.

```toml
# world.toml
[deps]
trantor-cli = { path = "../trantor-cli" }
trantor-process = { path = "../trantor-process" }
```

**Warning:** A child process is not confined by trantor-cli's `fs-confined`
and can open any file the OS allows the user. The main reason this is split
out from the core `cli` package is so this is auditable from the deps.

## Subprocess

`Subprocess.spawn!(cmd, { stdin, stdout, stderr })` takes each stream as
`Inherit` (the default), `Null`, `Pipe`, `Descriptor(Fs.Descriptor)` or
`ToStream(Streams.OutputStream)`. A descriptor comes from `File.Reader` or
`File.Writer`'s `descriptor`, so a child reads from or writes to a file with no
shell in between; the same descriptor on stdout and stderr merges them:

```roc
log = File.open_writer!(Path.utf8("build.log"))?
build = Cmd.new_str("make").spawn!({
    stdout: Descriptor(log.descriptor()),
    stderr: Descriptor(log.descriptor()) })?
status = build.wait!()?
```

A `Child` has `pid`, `stdin!`, `stdout!`, `stderr!` (each the same stream every
call, or `NotPiped`), `close_stdin!`, `wait!`, `try_wait!`, `signal!` and
`collect!`, and ends as `Exited(code)` or `Signaled(signal)`.

Dropping a child neither kills nor reaps it.

```roc
Cmd : { args : List(OsStr), clear_envs : Bool, envs : List(OsStr), program : OsStr }   # envs as key, value, key, value…
Stdio : [Inherit, Null, Pipe, Descriptor(Fs.Descriptor), ToStream(Streams.OutputStream)]
ExitStatus : [Exited(I32), Signaled(I32)]
Signal : [Term, Kill, Int, Hup, Quit, Usr1, Usr2]
CmdOutputSuccess : { stderr_bytes : List(U8), stdout_bytes : List(U8) }
CmdOutputFailure : { stderr_bytes : List(U8), stdout_bytes : List(U8), exit_code : I32 }
Child :: { handle : Handle, pid : I32 }
Handle :: Box(U64)                       # a host resource

# starting
Subprocess.spawn! : Cmd, { stdin ?: Stdio, stdout ?: Stdio, stderr ?: Stdio } => Try(Child, [Io(IOErr), ..])
Subprocess.can_execute! : OsStr => Try({}, [Io(IOErr)])   # access(X_OK) against the userland cwd, following links

# Child methods
pid : Child -> I32
stdin! : Child => Try(Streams.OutputStream, [NotPiped, ..])
stdout! : Child => Try(Streams.InputStream, [NotPiped, ..])
stderr! : Child => Try(Streams.InputStream, [NotPiped, ..])
close_stdin! : Child => {}
wait! : Child => Try(ExitStatus, [Io(IOErr), ..])           # closes stdin first
try_wait! : Child => Try([Running, Done(ExitStatus)], [Io(IOErr), ..])   # leaves stdin open
signal! : Child, Signal => Try({}, [Io(IOErr), ..])
collect! : Child, List(U8) => Try({ status : ExitStatus, stdout : List(U8), stderr : List(U8) }, [Io(IOErr), NotPiped, ..])
```

Pipes are OS pipes of about 64 KB. Reading one output to its end while the
child blocks writing a full pipe on the other deadlocks both: read them on the
same schedule, or use `collect!`, which writes stdin and reads both outputs on
separate threads and then waits. A `File.Reader`'s already-buffered bytes are
not seen by a child given its descriptor.

## Cmd

This is provided as part of the basic-cli 0.21 compatibility shim.

```roc
child = Cmd.new_str("sort").spawn!({ stdin: Pipe, stdout: Pipe })?
sorted = child.collect!(Str.to_utf8("pear\napple\n"))?
Stdout.write!(Str.from_utf8_lossy(sorted.stdout))?
```

```roc
Cmd :: { args : List(OsStr), clear_envs : Bool, envs : List((OsStr, OsStr)), program : OsStr }

# building
new : OsStr -> Cmd
arg : Cmd, OsStr -> Cmd
args : Cmd, List(OsStr) -> Cmd
env : Cmd, OsStr, OsStr -> Cmd
envs : Cmd, List((OsStr, OsStr)) -> Cmd
clear_envs : Cmd -> Cmd                  # PATH goes too: name the program by path, or add PATH back

# running, streams inherited
Cmd.exec! : OsStr, List(OsStr) => Try({}, [ExecFailed({ command : Str, exit_code : I32 }), FailedToGetExitCode({ command : Str, err : IOErr }), ..])
exec_cmd! : Cmd => Try({}, [ExecCmdFailed({ command : Str, exit_code : I32 }), FailedToGetExitCode({ command : Str, err : IOErr }), ..])
exec_exit_code! : Cmd => Try(I32, [FailedToGetExitCode({ command : Str, err : IOErr }), ..])
exec_status! : Cmd => Try(I32, [FailedToGetExitCode({ command : Str, err : IOErr }), ..])   # a signal death is the negated signal

# running, output captured
exec_output! : Cmd => Try({ stdout_utf8 : Str, stderr_utf8_lossy : Str }, [
    StdoutContainsInvalidUtf8({ cmd_str : Str, err : [BadUtf8({ problem : _, index : U64 })] }),
    NonZeroExitCode({ command : Str, exit_code : I32, stdout_utf8_lossy : Str, stderr_utf8_lossy : Str }),
    FailedToGetExitCode({ command : Str, err : IOErr }),
    ..])                                 # stdin is null
exec_output_inherit_stdin! : Cmd => Try({ stdout_utf8 : Str, stderr_utf8_lossy : Str }, [
    StdoutContainsInvalidUtf8({ cmd_str : Str, err : [BadUtf8({ problem : _, index : U64 })] }),
    NonZeroExitCode({ command : Str, exit_code : I32, stdout_utf8_lossy : Str, stderr_utf8_lossy : Str }),
    FailedToGetExitCode({ command : Str, err : IOErr }),
    ..])
exec_output_bytes! : Cmd => Try({ stderr_bytes : List(U8), stdout_bytes : List(U8) }, [NonZeroExitCodeB({ exit_code : I32, stdout_bytes : List(U8), stderr_bytes : List(U8) }), FailedToGetExitCodeB(IOErr), ..])

# starting
spawn! : Cmd, { stdin ?: Subprocess.Stdio, stdout ?: Subprocess.Stdio, stderr ?: Subprocess.Stdio } => Try(Subprocess.Child, [SpawnFailed({ command : Str, err : IOErr }), ..])
Cmd.check_available! : Str => Bool       # searches this process's PATH, as a spawn would

# rendering
to_str : Cmd -> Str
to_inspect : Cmd -> Str
```
