app [main!] { pf: platform "../target/trantor/myapp/platform/main.roc" }

import pf.OsStr exposing [OsStr]
import pf.Stdout
import pf.Cmd

## Perl prints, or with `exit` as its argument exits with, which of SIGWINCH (1)
## and SIGUSR1 (2) it started with blocked. The exiting child's stdout is the
## app's, so it prints nothing. Perl keeps the mask it is given, where a shell
## such as dash clears it.
report : List(Str)
report = [
	"-MPOSIX",
	"-e",
	"my $s = POSIX::SigSet->new; sigprocmask(SIG_BLOCK, undef, $s); my $n = ($s->ismember(SIGWINCH) ? 1 : 0) + ($s->ismember(SIGUSR1) ? 2 : 0); exit $n if @ARGV; print $n",
]

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	printed =
		match Cmd.exec_output!(Cmd.new_str("perl").args_str(report)) {
			Ok(out) => out.stdout_utf8
			Err(_) => "failed"
		}
	exited =
		match Cmd.exec_exit_code!(Cmd.new_str("perl").args_str(report.append("exit"))) {
			Ok(code) => code.to_str()
			Err(_) => "failed"
		}
	Stdout.line!("${printed} ${exited}")
}
