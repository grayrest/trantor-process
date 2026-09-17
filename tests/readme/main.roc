app [main!] { pf: platform "../target/trantor/app/platform/main.roc" }

import pf.OsStr exposing [OsStr]
import pf.Stdout
import pf.Path
import pf.File
import pf.Cmd

## README.md's examples, so they keep compiling and doing what it says.
sorted! : () => Try({}, _)
sorted! = || {
	child = Cmd.new_str("sort").spawn!({ stdin: Pipe, stdout: Pipe })?
	sorted = child.collect!(Str.to_utf8("pear\napple\n"))?
	Stdout.write!(Str.from_utf8_lossy(sorted.stdout))?
	Ok({})
}

logged! : () => Try(Str, _)
logged! = || {
	log = File.open_writer!(Path.utf8("build.log"))?
	build = Cmd.new_str("sh").args_str(["-c", "echo made; echo warned >&2"]).spawn!({ stdout: Descriptor(log.descriptor()), stderr: Descriptor(log.descriptor()) })?
	status = build.wait!()?
	text = Path.read_utf8!(Path.utf8("build.log"))?
	Path.delete!(Path.utf8("build.log"))?
	Ok("${Str.inspect(status)} ${Str.replace_each(text, "\n", " ")}")
}

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	sorted!()?
	Stdout.line!(logged!()?)
}
