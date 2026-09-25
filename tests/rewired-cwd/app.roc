app [main!] { pf: platform "../target/trantor/myapp/platform/main.roc" }

import pf.OsStr exposing [OsStr]
import pf.Stdout
import pf.Env
import pf.Path
import pf.Cmd

## The same divergence `relative-cwd` watches for, in a world that wired `cwd`
## to its own component: what a file op reads, where a child runs, and what
## directory a relative program name is checked against.
main! : List(OsStr) => Try({}, _)
main! = |_args| {
	Env.set_cwd!(Path.utf8("sub")) ? |_| RewiredCwdRefused
	marker = Path.read_utf8!(Path.utf8("marker.txt")) ?? "<none>"
	out = Cmd.exec_output!(Cmd.new_str("pwd")) ?? { stdout_utf8: "<failed>", stderr_utf8_lossy: "" }
	tool = Str.inspect(Cmd.check_available!("./toolx"))
	Stdout.line!("${Str.trim(marker)} ${Str.trim(out.stdout_utf8)} ${tool}")
}
