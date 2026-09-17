import IOErr exposing [IOErr]
import Subprocess
## How `Cmd`'s run-to-completion functions report a child's `ExitStatus`. They
## predate the union and keep their numbers (D-S2-13): these are the three
## mappings, pure so they are tested here rather than only through processes.
CmdStatus :: [].{
	## `exec_exit_code!`: a signal death is an error naming the signal.
	exit_code : Subprocess.ExitStatus -> Try(I32, IOErr)
	exit_code = |status| match status {
		Exited(code) => Ok(code)
		Signaled(sig) => Err(Other("child was killed by signal ${sig.to_str()}"))
	}
	## `exec_status!`: a signal death is the negated signal, which no exit code
	## can be (real codes are 0..=255).
	negated_signal : Subprocess.ExitStatus -> I32
	negated_signal = |status| match status {
		Exited(code) => code
		Signaled(sig) => -sig
	}
	## `exec_output!`: a signal death is a non-zero exit of -1, as
	## `Command::output` reported it.
	output_code : Subprocess.ExitStatus -> I32
	output_code = |status| match status {
		Exited(code) => code
		Signaled(_) => -1
	}
}

## `IOErr` has no equality, so the error arm is compared as its message.
message : Try(I32, IOErr) -> Try(I32, Str)
message = |r| r.map_err(IOErr.to_str)

expect message(CmdStatus.exit_code(Exited(3))) == Ok(3)
expect message(CmdStatus.exit_code(Signaled(15))) == Err("child was killed by signal 15")
expect CmdStatus.negated_signal(Exited(0)) == 0
expect CmdStatus.negated_signal(Signaled(15)) == -15
expect CmdStatus.output_code(Exited(2)) == 2
expect CmdStatus.output_code(Signaled(9)) == -1
