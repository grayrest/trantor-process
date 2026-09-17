app [main!] { pf: platform "../target/trantor/myapp/platform/main.roc" }

import pf.OsStr exposing [OsStr]
import pf.Stdout
import pf.File
import pf.Path
import pf.Env
import pf.Cmd

read_all! : Str => Try(Str, _)
read_all! = |name| {
	r = File.open_reader!(Path.utf8(name)) ? |_| OpenFailed
	loop!(r, 0)
}

loop! : File.Reader, U64 => Try(Str, _)
loop! = |r, n|
	match r.read_line!() {
		Ok([]) => Ok("eof${Str.inspect(n)}")
		Ok(_) => loop!(r, n + 1)
		Err(LineTooLong) => Ok("toolong")
		Err(FileErr(_)) => Ok("fileerr")
	}

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	short = read_all!("ok.txt")?
	long = read_all!("long.txt")?
	set = match Env.var!(OsStr.utf8("BADVAR")) {
		Ok(v) => match OsStr.to_raw(v) {
			UnixBytes(_) => "bytes"
			Utf8(_) => "utf8"
			WindowsU16s(_) => "u16s"
		}
		Err(VarNotFound(_)) => "notfound"
		Err(_) => "other"
	}
	unset = match Env.var!(OsStr.utf8("DEFINITELY_UNSET_XYZ")) {
		Ok(_) => "found"
		Err(VarNotFound(_)) => "notfound"
		Err(_) => "other"
	}
	code = match Cmd.exec_exit_code!(Cmd.new_str("sh").args_str(["-c", "kill -TERM $$"])) {
		Ok(c) => "ok${Str.inspect(c)}"
		Err(FailedToGetExitCode(_)) => "err"
	}
	status = match Cmd.exec_status!(Cmd.new_str("sh").args_str(["-c", "kill -TERM $$"])) {
		Ok(c) => Str.inspect(c)
		Err(FailedToGetExitCode(_)) => "err"
	}
	plain = match Cmd.exec_exit_code!(Cmd.new_str("sh").args_str(["-c", "exit 3"])) {
		Ok(c) => Str.inspect(c)
		Err(FailedToGetExitCode(_)) => "err"
	}
	Stdout.line!("${short} ${long} ${set} ${unset} ${code} ${status} ${plain}")
}
