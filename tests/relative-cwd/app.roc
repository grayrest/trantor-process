app [main!] { pf: platform "../target/trantor/myapp/platform/main.roc" }

import pf.OsStr exposing [OsStr]
import pf.Stdout
import pf.Env
import pf.Path
import pf.Cmd

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	Env.set_cwd!(Path.utf8("sub")) ? |_| RelativeCwdRefused
	marker = Path.read_utf8!(Path.utf8("marker.txt")) ?? "<none>"
	out = Cmd.exec_output!(Cmd.new_str("pwd")) ?? { stdout_utf8: "<failed>", stderr_utf8_lossy: "" }
	missing = match Env.set_cwd!(Path.utf8("/no/such/directory")) {
		Ok({}) => "accepted"
		Err(InvalidCwd(_)) => "refused"
	}
	file = match Env.set_cwd!(Path.utf8("/etc/hosts")) {
		Ok({}) => "accepted"
		Err(InvalidCwd(_)) => "refused"
	}
	Stdout.line!("${Str.trim(marker)} ${Str.trim(out.stdout_utf8)} ${missing} ${file}")
}
