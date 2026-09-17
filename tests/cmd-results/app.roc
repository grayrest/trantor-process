app [main!] { pf: platform "../target/trantor/myapp/platform/main.roc" }

import pf.OsStr exposing [OsStr]
import pf.Stdout
import pf.IOErr
import pf.Cmd
import pf.Env
import pf.Path

sh : Str -> Cmd
sh = |script| Cmd.new_str("sh").args_str(["-c", script])

## Cmd's run-to-completion results through real processes, now that they run
## over spawn!: the codes, the captured bytes and the error shapes basic-cli
## programs match on.
main! : List(OsStr) => Try({}, _)
main! = |args| if List.len(args) > 1 { path_check!() } else { results!() }

## Run from a directory holding the test's tools with `PATH=/nope:`: the empty
## entry is the working directory to both `check_available!` and a spawn, and
## each must agree on every tool, links included.
path_check! : () => Try({}, _)
path_check! = || Stdout.line!(Str.join_with(agreement!(["local-tool", "dangling", "noexec-link", "tool-link", "dir-link", "group-only", "deep-tool"]), " "))

agreement! : List(Str) => List(Str)
agreement! = |names| match names {
	[] => []
	[name, .. as rest] => {
		available = Str.inspect(Cmd.check_available!(name))
		ran = match Cmd.new_str(name).exec_output!() {
			Ok({ stdout_utf8, .. }) => Str.trim(stdout_utf8)
			Err(_) => "did-not-run"
		}
		List.concat(["${name}:${available}:${ran}"], agreement!(rest))
	}
}

results! : () => Try({}, _)
results! = || {
	nonzero = match sh("printf out; printf err >&2; exit 3").exec_output!() {
		Ok(_) => "ok"
		Err(NonZeroExitCode({ exit_code, stdout_utf8_lossy, stderr_utf8_lossy, .. })) => "${exit_code.to_str()}:${stdout_utf8_lossy}:${stderr_utf8_lossy}"
		Err(_) => "other"
	}
	killed = match sh("kill -TERM $$").exec_output!() {
		Err(NonZeroExitCode({ exit_code, .. })) => exit_code.to_str()
		_ => "other"
	}
	bytes = match sh("printf ab").exec_output_bytes!() {
		Ok({ stdout_bytes, .. }) => Str.inspect(stdout_bytes)
		Err(_) => "err"
	}
	inherited = match Cmd.new_str("cat").exec_output_inherit_stdin!() {
		Ok({ stdout_utf8, .. }) => stdout_utf8
		Err(_) => "err"
	}
	nulled = match Cmd.new_str("cat").exec_output!() {
		Ok({ stdout_utf8, .. }) => if Str.is_empty(stdout_utf8) { "empty" } else { stdout_utf8 }
		Err(_) => "err"
	}
	signal_message = match sh("kill -TERM $$").exec_exit_code!() {
		Err(FailedToGetExitCode({ err, .. })) => IOErr.to_str(err)
		_ => "other"
	}
	status = match sh("kill -TERM $$").exec_status!() {
		Ok(code) => code.to_str()
		Err(_) => "err"
	}
	exec_failed = match Cmd.exec!("sh", ["-c", "exit 4"]) {
		Err(ExecFailed({ exit_code, .. })) => exit_code.to_str()
		_ => "other"
	}
	available = Str.inspect(Cmd.check_available!("sh"))
	# The working directory removed after set_cwd!: named, not NotFound.
	original = Env.cwd!() ? |_| NoCwd
	gone = Path.join(original, "gone")
	Path.create_dir!(gone)?
	Env.set_cwd!(gone)?
	Path.delete_empty!(gone)?
	cwd_gone = match sh("true").exec_exit_code!() {
		Err(FailedToGetExitCode({ err: Other(message), .. })) => if Str.contains(message, "no longer exists") { "cwd-gone" } else { "other-message" }
		Err(FailedToGetExitCode({ err: NotFound, .. })) => "notfound"
		_ => "other"
	}
	Env.set_cwd!(original)?
	Stdout.line!("${nonzero} ${killed} ${bytes} ${inherited} ${nulled} ${Str.replace_each(signal_message, " ", "_")} ${status} ${exec_failed} ${available} ${cwd_gone}")
}
