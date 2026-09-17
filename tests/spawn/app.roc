app [main!] { pf: platform "../target/trantor/myapp/platform/main.roc" }

import pf.OsStr exposing [OsStr]
import pf.Stdout
import pf.Env
import pf.Path
import pf.File
import pf.Fs
import pf.Streams
import pf.Cli
import pf.Subprocess
import pf.Cmd

sh : Str -> Subprocess.Cmd
sh = |script| { program: OsStr.utf8("sh"), args: [OsStr.utf8("-c"), OsStr.utf8(script)], envs: [], clear_envs: False }

status : Subprocess.ExitStatus -> Str
status = |st| match st {
	Exited(code) => "exited${code.to_str()}"
	Signaled(sig) => "signaled${sig.to_str()}"
}

## Read a stream to its end, counting bytes, one `stdout!` call per read: the
## same stream comes back each time, so nothing a read buffered is lost.
count_to_end! : Subprocess.Child, U64 => Try(U64, [Failed(Str)])
count_to_end! = |child, total| {
	chunk = lift(Streams.read!(lift(child.stdout!())?, 4096))?
	if List.is_empty(chunk) { Ok(total) } else { count_to_end!(child, total + List.len(chunk)) }
}

## 200 KB through a pipe, far past its 64 KB buffer, read as it arrives.
streamed! : () => Try(Str, [Failed(Str)])
streamed! = || {
	child = lift(Subprocess.spawn!(sh("head -c 200000 /dev/zero | tr '\\0' a"), { stdout: Pipe }))?
	n = lift(count_to_end!(child, 0))?
	Ok("${n.to_str()},${status(lift(child.wait!())?)}")
}

## Both outputs piped and each larger than a pipe buffer, plus 100 KB of input:
## `collect!` has to write and read all three at once or it deadlocks.
collected! : () => Try(Str, [Failed(Str)])
collected! = || {
	both = lift(Subprocess.spawn!(sh("head -c 100000 /dev/zero | tr '\\0' e >&2; head -c 100000 /dev/zero | tr '\\0' o"), { stdout: Pipe, stderr: Pipe }))?
	b = lift(both.collect!([]))?
	input = List.repeat('i', 100000)
	cat = lift(Subprocess.spawn!(sh("cat"), { stdin: Pipe, stdout: Pipe, stderr: Pipe }))?
	c = lift(cat.collect!(input))?
	Ok("${List.len(b.stdout).to_str()}/${List.len(b.stderr).to_str()},${Str.inspect(c.stdout == input)},${status(c.status)}")
}

abs! : Str => List(U8)
abs! = |name| {
	cwd = Env.cwd!() ?? Path.utf8(".")
	Str.to_utf8("${Path.display(cwd)}/${name}")
}

## A file writer's descriptor on both outputs merges them into the file; a file
## reader's descriptor is the child's stdin.
descriptors! : () => Try(Str, [Failed(Str)])
descriptors! = || {
	writer = lift(File.open_writer!(Path.utf8("merged.txt")))?
	merged = lift(Subprocess.spawn!(sh("echo out; echo err >&2"), { stdout: Descriptor(writer.descriptor()), stderr: Descriptor(writer.descriptor()) }))?
	merged_status = status(lift(merged.wait!())?)
	reader = lift(File.open_reader!(Path.utf8("input.txt")))?
	fed = lift(Subprocess.spawn!(sh("tr a-z A-Z"), { stdin: Descriptor(reader.descriptor()), stdout: Pipe }))?
	upper = lift(fed.collect!([]))?
	merged_text = Str.replace_each(lift(Path.read_utf8!(Path.utf8("merged.txt")))?, "\n", "+")
	Ok("${merged_text}${merged_status},${Str.trim(Str.from_utf8_lossy(upper.stdout))}")
}

## An output sent to a stream with a file under it.
to_stream! : () => Try(Str, [Failed(Str)])
to_stream! = || {
	root = Fs.preopens!({}).first() ?? crash("no preopen")
	d = lift(Fs.open_at!(root, abs!("streamed.txt"), { read: False, write: True, create: True, truncate: True }))?
	s = lift(Fs.write_via_stream!(d, 0))?
	child = lift(Subprocess.spawn!(sh("printf via-stream"), { stdout: ToStream(s) }))?
	_ = lift(child.wait!())?
	lift(Path.read_utf8!(Path.utf8("streamed.txt")))
}

## Written by hand, closed, then read: the child sees end of input.
hand_fed! : () => Try(Str, [Failed(Str)])
hand_fed! = || {
	child = lift(Subprocess.spawn!(sh("cat"), { stdin: Pipe, stdout: Pipe }))?
	lift(Streams.write!(lift(child.stdin!())?, Str.to_utf8("by hand")))?
	child.close_stdin!()
	out = lift(Streams.read!(lift(child.stdout!())?, 100))?
	Ok("${Str.from_utf8_lossy(out)},${status(lift(child.wait!())?)}")
}

## Running until signalled; a signal death is Signaled, not a code.
signalled! : () => Try(Str, [Failed(Str)])
signalled! = || {
	child = lift(Subprocess.spawn!(sh("exec sleep 30"), {}))?
	before = match lift(child.try_wait!())? {
		Running => "running"
		Done(st) => status(st)
	}
	lift(child.signal!(Term))?
	after = status(lift(child.wait!())?)
	pid_ok = child.pid() > 0
	Ok("${before},${after},${Str.inspect(pid_ok)}")
}

## An unpiped stream is NotPiped, and so is input for an unpiped stdin.
not_piped! : () => Try(Str, [Failed(Str)])
not_piped! = || {
	child = lift(Subprocess.spawn!(sh("exit 7"), { stdout: Null }))?
	out = match child.stdout!() {
		Ok(_) => "piped"
		Err(NotPiped) => "notpiped"
	}
	input = match child.collect!([1]) {
		Ok(_) => "collected"
		Err(NotPiped) => "notpiped"
		Err(Io(_)) => "io"
	}
	Ok("${out},${input},${status(lift(child.wait!())?)}")
}

missing! : () => Str
missing! = || match Subprocess.spawn!({ program: OsStr.utf8("no-such-program-xyz"), args: [], envs: [], clear_envs: False }, {}) {
	Ok(_) => "spawned"
	Err(Io(NotFound)) => "notfound"
	Err(Io(e)) => "err:${Str.inspect(e)}"
}

## Each case's failures, made one closed union: the raw layers answer closed
## unions, which `?` cannot widen into a function's open one.
lift : Try(a, e) -> Try(a, [Failed(Str)])
lift = |r| r.map_err(|e| Failed(Str.inspect(e)))

## `yes` into `head -c 1`'s stdin pipe; 1 when `yes` died of SIGPIPE.
## The parent writes one byte into `head -c 2`'s stdin, and that write is
## over before `yes` exists; `yes` supplies the second byte and dies of SIGPIPE
## once `head` exits. 1 when it did. A parent write that left the no-SIGPIPE
## flag on the shared pipe makes `yes` exit 1 instead, every time.
sigpipe_run! : () => Try(U64, [Failed(Str)])
sigpipe_run! = || {
	reader = lift(Subprocess.spawn!(sh("head -c 2 >/dev/null"), { stdin: Pipe }))?
	lift(Streams.write!(lift(reader.stdin!())?, Str.to_utf8("p")))?
	producer = lift(Subprocess.spawn!({ program: OsStr.utf8("yes"), args: [], envs: [], clear_envs: False }, { stdout: ToStream(lift(reader.stdin!())?) }))?
	reader.close_stdin!()
	_ = lift(reader.wait!())?
	match lift(producer.wait!())? {
		Signaled(13) => Ok(1)
		_ => Ok(0)
	}
}

sigpipe_runs! : U64, U64 => Try(U64, [Failed(Str)])
sigpipe_runs! = |left, count| if left == 0 { Ok(count) } else { sigpipe_runs!(left - 1, count + sigpipe_run!()?) }

## Review regressions, each a case that crashed, killed the app or lost bytes.
##
## `stdout!` as the child's last use: the handle drops in that call.
last_use! : Subprocess.Child => Try(List(U8), [Failed(Str)])
last_use! = |child| lift(Streams.read!(lift(child.stdout!())?, 100))

regressions! : () => Try(Str, [Failed(Str)])
regressions! = || {
	echoed = Str.from_utf8_lossy(last_use!(lift(Subprocess.spawn!(sh("printf last"), { stdout: Pipe }))?)?)
	# The child exits without reading 1 MB of input: BrokenPipe, not SIGPIPE.
	gone = lift(Subprocess.spawn!(sh("exit 0"), { stdin: Pipe }))?
	piped_away = match gone.collect!(List.repeat('x', 1_000_000)) {
		Ok(done) => status(done.status)
		Err(_) => "collect-err"
	}
	# Bytes a writer already wrote are not overwritten by a child given its
	# descriptor, and the writer carries on after the child's.
	writer = lift(File.open_writer!(Path.utf8("shared.txt")))?
	lift(writer.write_utf8!("head,"))?
	shared = lift(Subprocess.spawn!(sh("printf child,"), { stdout: Descriptor(writer.descriptor()) }))?
	_ = lift(shared.wait!())?
	lift(writer.write_utf8!("tail"))?
	shared_text = lift(Path.read_utf8!(Path.utf8("shared.txt")))?
	# A reaped child is not signalled.
	reaped = lift(Subprocess.spawn!(sh("exit 0"), {}))?
	_ = lift(reaped.wait!())?
	late_signal = match reaped.signal!(Kill) {
		Ok({}) => "SENT"
		Err(_) => "refused"
	}
	# Input after stdin was closed is refused, not silently dropped.
	closed = lift(Subprocess.spawn!(sh("cat"), { stdin: Pipe, stdout: Pipe }))?
	closed.close_stdin!()
	late_input = match closed.collect!([1, 2, 3]) {
		Ok(_) => "DROPPED"
		Err(NotPiped) => "notpiped"
		Err(Io(_)) => "io"
	}
	_ = lift(closed.wait!())?
	# A child handed another child's stdin pipe keeps SIGPIPE's default, after
	# the parent has written into that pipe (D-S2-26): every run.
	runs = 3
	signaled = sigpipe_runs!(runs, 0)?
	pipeline = if signaled == runs { "sigpiped" } else { "sigpiped-${signaled.to_str()}-of-${runs.to_str()}" }
	# An append stream that seeks to the end cannot be handed to a child, which
	# would write at the cursor instead (D-S2-31).
	root = Fs.preopens!({}).first() ?? crash("no preopen")
	plain = lift(Fs.open_at!(root, abs!("shared.txt"), { write: True }))?
	refused = match Subprocess.spawn!(sh("printf x"), { stdout: ToStream(lift(Fs.append_via_stream!(plain))?) }) {
		Ok(_) => "HANDED"
		Err(_) => "refused"
	}
	# A child inheriting stdin reads it to its end cleanly, including when this
	# process started with stdin closed: the driver's /dev/null must survive
	# exec (trantor D-S2-29).
	inherited = match Cmd.new_str("sh").args_str(["-c", "cat >/dev/null; echo rc=$?"]).exec_output_inherit_stdin!() {
		Ok({ stdout_utf8, .. }) => Str.trim(stdout_utf8)
		Err(_) => "exec-failed"
	}
	Ok("${echoed},${piped_away},${shared_text},${late_signal},${late_input},${pipeline},${refused},${inherited}")
}

## `Cmd.spawn!` is the same child, from the builder; a missing program is
## SpawnFailed naming the command.
cmd_spawn! : () => Str
cmd_spawn! = || {
	piped = match Cmd.new_str("sh").args_str(["-c", "printf via-cmd"]).spawn!({ stdout: Pipe }) {
		Ok(child) => match child.collect!([]) {
			Ok(done) => Str.from_utf8_lossy(done.stdout)
			Err(_) => "collect-failed"
		}
		Err(SpawnFailed(_)) => "spawn-failed"
	}
	missing = match Cmd.new_str("no-such-program-xyz").spawn!({}) {
		Ok(_) => "spawned"
		Err(SpawnFailed({ command, err: NotFound })) => if Str.contains(command, "no-such-program-xyz") { "spawnfailed-named" } else { "spawnfailed-unnamed" }
		Err(SpawnFailed(_)) => "spawnfailed-other"
	}
	"${piped},${missing}"
}

outcome : Try(Str, [Failed(Str)]) -> Str
outcome = |r| match r {
	Ok(s) => s
	Err(Failed(e)) => "err:${e}"
}

## This process's stdout lent to a child: the child writes to it, and it is
## still open for the app afterwards. The fd crosses as a `ToStream` redirect,
## which the host duplicates; it used to take the number over and close it.
borrowed! : () => Try({}, _)
borrowed! = || {
	match Subprocess.spawn!(sh("echo child"), { stdout: ToStream(Cli.get_stdout!({})) }) {
		Ok(child) => {
			_ = child.wait!()
			Stdout.line!("parent")
		}
		Err(_) => Stdout.line!("spawn-failed")
	}
}

## A child reading its stdin pipe stays Running until stdin is closed, which
## `try_wait!` does not do: a poll loop that expects otherwise never ends.
polled! : () => Try(Str, [Failed(Str)])
polled! = || {
	child = lift(Subprocess.spawn!(sh("cat > /dev/null"), { stdin: Pipe }))?
	lift(Streams.write!(lift(child.stdin!())?, Str.to_utf8("input")))?
	before = match child.try_wait!() {
		Ok(Running) => "running"
		Ok(Done(_)) => "done"
		Err(_) => "err"
	}
	child.close_stdin!()
	after = match child.wait!() {
		Ok(Exited(0)) => "exited0"
		Ok(other) => Str.inspect(other)
		Err(_) => "err"
	}
	Ok("${before} ${after}")
}

main! : List(OsStr) => Try({}, _)
main! = |args| if List.len(args) > 2 { Stdout.line!(outcome(polled!())) } else if List.len(args) > 1 { borrowed!() } else {
	cases = [
		outcome(streamed!()),
		outcome(collected!()),
		outcome(descriptors!()),
		outcome(to_stream!()),
		outcome(hand_fed!()),
		outcome(signalled!()),
		outcome(not_piped!()),
		missing!(),
		cmd_spawn!(),
		outcome(regressions!()),
	]
	Stdout.line!(Str.join_with(cases, " "))
}
