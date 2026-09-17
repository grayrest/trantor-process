app [main!] { pf: platform "../target/trantor/myapp/platform/main.roc" }

import pf.OsStr exposing [OsStr]
import pf.Stdout
import pf.Cmd

## What `check_available!` says, and what a spawn does, for a program outside
## the confined root.
main! : List(OsStr) => Try({}, _)
main! = |_args| {
	available = Str.inspect(Cmd.check_available!("sh"))
	ran = match Cmd.new_str("sh").args_str(["-c", "printf ran"]).exec_output!() {
		Ok({ stdout_utf8, .. }) => stdout_utf8
		Err(_) => "did-not-run"
	}
	Stdout.line!("${available} ${ran}")
}
