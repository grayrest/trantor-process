import IOErr exposing [IOErr]
import Subprocess
import CmdStatus
import OsStr exposing [OsStr]
import Env
import Path exposing [Path]

## Build and run child processes with native-safe programs, arguments, and
## environment values.
Cmd :: {
	args : List(OsStr),
	clear_envs : Bool,
	envs : List((OsStr, OsStr)),
	program : OsStr,
}.{

	## Simplest way to execute a command by name with arguments.
	## Stdin, stdout, and stderr are inherited from the parent process.
	##
	## If you want to capture the output, use [exec_output!] instead.
	##
	## ```roc
	## Cmd.exec!("echo", ["hello world"])?
	## ```
	exec! : OsStr, List(OsStr) => Try({}, [ExecFailed({ command : Str, exit_code : I32 }), FailedToGetExitCode({ command : Str, err : IOErr }), ..])
	exec! = |program, arguments| {
		command = "${OsStr.display(program)} ${Str.join_with(arguments.map(OsStr.display), " ")}"

		exit_code = new(program)
			.args(arguments)
			.exec_exit_code!()?

		if exit_code == 0 {
			Ok({})
		} else {
			Err(ExecFailed({ command, exit_code }))
		}
	}

	## Execute a Cmd (using the builder pattern).
	## Stdin, stdout, and stderr are inherited from the parent process.
	##
	## You should prefer using [exec!] instead, only use this if you want to use [env], [envs] or [clear_envs].
	## If you want to capture the output, use [exec_output!] instead.
	##
	## ```roc
	## Cmd.new("cargo")
	##     .arg("build")
	##     .env("RUST_BACKTRACE", "1")
	##     .exec_cmd!()?
	## ```
	exec_cmd! : Cmd => Try({}, [ExecCmdFailed({ command : Str, exit_code : I32 }), FailedToGetExitCode({ command : Str, err : IOErr }), ..])
	exec_cmd! = |cmd| {
		command = to_str(cmd)
		exit_code = exec_exit_code!(cmd)?

		if exit_code == 0 {
			Ok({})
		} else {
			Err(ExecCmdFailed({ command, exit_code }))
		}
	}

	## Execute command and capture stdout and stderr as UTF-8 strings.
	## Invalid UTF-8 sequences are replaced with the Unicode replacement character.
	##
	## Use [exec_output_bytes!] instead if you want to capture the output in the original form as bytes.
	## [exec_output_bytes!] may also be used for maximum performance, because you may be able to avoid unnecessary UTF-8 conversions.
	##
	## ```roc
	## cmd_output =
	##     Cmd.new("echo")
	##         .args(["Hi"])
	##         .exec_output!()?
	##
	## Stdout.line!("Echo output: ${cmd_output.stdout_utf8}")?
	## ```
	exec_output! : Cmd => Try({ stdout_utf8 : Str, stderr_utf8_lossy : Str }, [StdoutContainsInvalidUtf8({ cmd_str : Str, err : [BadUtf8({ problem : _, index : U64 })] }), NonZeroExitCode({ command : Str, exit_code : I32, stdout_utf8_lossy : Str, stderr_utf8_lossy : Str }), FailedToGetExitCode({ command : Str, err : IOErr }), ..])
	exec_output! = |cmd| {
		cmd_str = to_str(cmd)
		exec_try = captured!(cmd, Null)

		match exec_try {
			Ok({ stderr_bytes, stdout_bytes }) => {
				stdout_utf8 = Str.from_utf8(stdout_bytes)
					.map_err(|err| StdoutContainsInvalidUtf8({ cmd_str, err }))?

				stderr_utf8_lossy = Str.from_utf8_lossy(stderr_bytes)

				Ok({ stdout_utf8, stderr_utf8_lossy })
			}

			Err(NonZeroExitCode({ exit_code, stderr_bytes, stdout_bytes })) => {
				stdout_utf8_lossy = Str.from_utf8_lossy(stdout_bytes)
				stderr_utf8_lossy = Str.from_utf8_lossy(stderr_bytes)

				Err(NonZeroExitCode({ command: cmd_str, exit_code, stdout_utf8_lossy, stderr_utf8_lossy }))
			}

			Err(FailedToGetExitCode(err)) => Err(FailedToGetExitCode({ command: cmd_str, err }))
		}
	}

	## [exec_output!], but with the child's stdin INHERITED rather than null.
	##
	## `Command::output` nulls stdin, which is right for most captured commands
	## and wrong for one whose whole job is to read. Use this where the child
	## may consume what was piped to this process -- a `cat` with no arguments,
	## a `read`, a prompt.
	exec_output_inherit_stdin! : Cmd => Try({ stdout_utf8 : Str, stderr_utf8_lossy : Str }, [StdoutContainsInvalidUtf8({ cmd_str : Str, err : [BadUtf8({ problem : _, index : U64 })] }), NonZeroExitCode({ command : Str, exit_code : I32, stdout_utf8_lossy : Str, stderr_utf8_lossy : Str }), FailedToGetExitCode({ command : Str, err : IOErr }), ..])
	exec_output_inherit_stdin! = |cmd| {
		cmd_str = to_str(cmd)
		exec_try = captured!(cmd, Inherit)

		match exec_try {
			Ok({ stderr_bytes, stdout_bytes }) => {
				stdout_utf8 = Str.from_utf8(stdout_bytes)
					.map_err(|err| StdoutContainsInvalidUtf8({ cmd_str, err }))?

				stderr_utf8_lossy = Str.from_utf8_lossy(stderr_bytes)

				Ok({ stdout_utf8, stderr_utf8_lossy })
			}

			Err(NonZeroExitCode({ exit_code, stderr_bytes, stdout_bytes })) => {
				stdout_utf8_lossy = Str.from_utf8_lossy(stdout_bytes)
				stderr_utf8_lossy = Str.from_utf8_lossy(stderr_bytes)

				Err(NonZeroExitCode({ command: cmd_str, exit_code, stdout_utf8_lossy, stderr_utf8_lossy }))
			}

			Err(FailedToGetExitCode(err)) => Err(FailedToGetExitCode({ command: cmd_str, err }))
		}
	}

	## Execute command and capture stdout and stderr in the original form as bytes.
	##
	## Use [exec_output!] instead if you want to get the output as UTF-8 strings.
	##
	## ```roc
	## cmd_output =
	##     Cmd.new("echo")
	##         .args(["Hi"])
	##         .exec_output_bytes!()?
	##
	## Stdout.line!("${Str.inspect(cmd_output_bytes)}")? # {stderr_bytes: [], stdout_bytes: [72, 105, 10]}
	## ```
	exec_output_bytes! : Cmd => Try({ stderr_bytes : List(U8), stdout_bytes : List(U8) }, [NonZeroExitCodeB({ exit_code : I32, stdout_bytes : List(U8), stderr_bytes : List(U8) }), FailedToGetExitCodeB(IOErr), ..])
	exec_output_bytes! = |cmd| {
		exec_try = captured!(cmd, Null)

		match exec_try {
			Ok({ stderr_bytes, stdout_bytes }) =>
				Ok({ stdout_bytes, stderr_bytes })

			Err(NonZeroExitCode({ exit_code, stderr_bytes, stdout_bytes })) => {
				Err(NonZeroExitCodeB({ exit_code, stdout_bytes, stderr_bytes }))
			}

			Err(FailedToGetExitCode(err)) => {
				Err(FailedToGetExitCodeB(err))
			}
		}
	}

	## Execute a command and return its exit code.
	## Stdin, stdout, and stderr are inherited from the parent process.
	##
	## You should prefer using [exec!] or [exec_cmd!] instead, only use this if you want to take a specific action based on a **specific non-zero exit code**.
	## For example, `roc check` returns exit code 1 if there are errors, and exit code 2 if there are only warnings.
	## So, you could use `exec_exit_code!` to ignore warnings on `roc check`.
	##
	## ```roc
	## exit_code = Cmd.new("cat").arg("non_existent.txt").exec_exit_code!()?
	## ```
	exec_exit_code! : Cmd => Try(I32, [FailedToGetExitCode({ command : Str, err : IOErr }), ..])
	exec_exit_code! = |cmd| {
		command = to_str(cmd)

		match waited!(cmd) {
			Ok(status) => CmdStatus.exit_code(status).map_err(|err| FailedToGetExitCode({ command, err }))
			Err(io_err) => Err(FailedToGetExitCode({ command, err: io_err }))
		}
	}

	## Execute and return the child's exit code, or the NEGATED signal that killed
	## it -- `-15` for a child terminated by SIGTERM.
	##
	## `exec_exit_code!` collapses a signal death into an error, which loses WHICH
	## signal and cannot be told from a genuine exit code of 143. A Unix exit code
	## is 0..=255, so a negative result here is unambiguous; the type is `I32`
	## for Windows, whose codes are the full width (D-S2-12).
	##
	## ```roc
	## code = Cmd.exec_status!(Cmd.new_str("sh") |> Cmd.args_str(["-c", "sleep 10"]))?
	## ```
	exec_status! : Cmd => Try(I32, [FailedToGetExitCode({ command : Str, err : IOErr }), ..])
	exec_status! = |cmd| {
		command = to_str(cmd)

		match waited!(cmd) {
			Ok(status) => Ok(CmdStatus.negated_signal(status))
			Err(io_err) => Err(FailedToGetExitCode({ command, err: io_err }))
		}
	}

	## Start the command without waiting for it, each standard stream as given
	## (all default to `Inherit`). The `Child` is `Subprocess`'s: pipe to and
	## from it, wait for it, signal it, or `collect!` its output.
	##
	## ```roc
	## child = Cmd.new_str("sort").spawn!({ stdin: Pipe, stdout: Pipe })?
	## done = child.collect!(Str.to_utf8("b\na\n"))?
	## ```
	spawn! : Cmd, { stdin ?: Subprocess.Stdio, stdout ?: Subprocess.Stdio, stderr ?: Subprocess.Stdio } => Try(Subprocess.Child, [SpawnFailed({ command : Str, err : IOErr }), ..])
	spawn! = |cmd, opts| {
		stdio = { stdin: opts.?stdin ?? Inherit, stdout: opts.?stdout ?? Inherit, stderr: opts.?stderr ?? Inherit }
		match Subprocess.spawn!(to_host_cmd(cmd), stdio) {
			Ok(child) => Ok(child)
			Err(Io(err)) => Err(SpawnFailed({ command: to_str(cmd), err }))
		}
	}

	## Create a new command with the given program name. Use a function that starts with `exec_` to execute it.
	##
	## ```roc
	## cmd = Cmd.new("ls")
	## ```
	new : OsStr -> Cmd
	new = |program| {
		args: [],
		clear_envs: Bool.False,
		envs: [],
		program,
	}

	## Create a new command from a Roc string.
	new_str : Str -> Cmd
	new_str = |program| new(OsStr.from_str(program))

	## Add a single argument to the command.
	## ❗ Shell features like variable substitution (e.g. `$FOO`), glob patterns (e.g. `*.txt`), ... are not available.
	##
	## ```roc
	## cmd = Cmd.new("ls").arg("-l")
	## ```
	arg : Cmd, OsStr -> Cmd
	arg = |cmd, a| {
		..cmd,
		args: cmd.args.append(a),
	}

	## Add a single string argument to the command.
	arg_str : Cmd, Str -> Cmd
	arg_str = |cmd, a| arg(cmd, OsStr.from_str(a))

	## Add multiple arguments to the command.
	## ❗ Shell features like variable substitution (e.g. `$FOO`), glob patterns (e.g. `*.txt`), ... are not available.
	##
	## ```roc
	## cmd = Cmd.new("ls").args(["-l", "-a"])
	## ```
	args : Cmd, List(OsStr) -> Cmd
	args = |cmd, new_args| {
		..cmd,
		args: cmd.args.concat(new_args),
	}

	## Add multiple string arguments to the command.
	args_str : Cmd, List(Str) -> Cmd
	args_str = |cmd, new_args| args(cmd, new_args.map(OsStr.from_str))

	## Add a single environment variable to the command.
	##
	##
	## ```roc
	## cmd = Cmd.new("env").env("FOO", "bar") # add the environment variable "FOO" with value "bar"
	## ```
	env : Cmd, OsStr, OsStr -> Cmd
	env = |cmd, key, value| {
		{ ..cmd, envs: cmd.envs.append((key, value)) }
	}

	## Add a single string environment variable to the command.
	env_str : Cmd, Str, Str -> Cmd
	env_str = |cmd, key, value| env(cmd, OsStr.from_str(key), OsStr.from_str(value))

	## Add multiple environment variables to the command.
	##
	## ```roc
	## cmd = Cmd.new("env").envs([("FOO", "bar"), ("BAZ", "qux")])
	## ```
	envs : Cmd, List((OsStr, OsStr)) -> Cmd
	envs = |cmd, pairs| { ..cmd, envs: cmd.envs.concat(pairs) }

	## Add multiple string environment variables to the command.
	envs_str : Cmd, List((Str, Str)) -> Cmd
	envs_str = |cmd, pairs| {
		arg_pairs = pairs.map(|(key, value)| (OsStr.from_str(key), OsStr.from_str(value)))
		envs(cmd, arg_pairs)
	}

	## Clear all environment variables before running the command.
	## Only environment variables added via `env` or `envs` will be available.
	## Useful if you want a clean command run that does not behave unexpectedly if the user has some env var set.
	##
	## ```roc
	## cmd =
	##     Cmd.new("env")
	##         .clear_envs()
	##         .env("ONLY_THIS", "visible")
	## ```
	## The child's `PATH` goes with the rest of the environment, so a program
	## named without a path separator is then looked up on the default search
	## path; give it as a path, or add `PATH` back with `env`.
	clear_envs : Cmd -> Cmd
	clear_envs = |cmd| { ..cmd, clear_envs: Bool.True }

	## Report whether `command` can be found on the system as something runnable.
	##
	## A bare name (like `"git"`) is looked up across the `PATH` entries; a name
	## containing a path separator is checked as-is. On Windows the candidate
	## extensions come from `%PATHEXT%`.
	##
	## The search reads this process's `PATH`. A `Cmd` carrying its own `PATH`,
	## or built with `clear_envs`, is spawned with that environment instead, so
	## this answers for a different search path than such a spawn uses.
	##
	## On Unix this asks whether this user may execute the candidate, following
	## symlinks, as a spawn does: an execute bit for someone else, a file on a
	## `noexec` mount, a directory, a link to one, and a FIFO are all not
	## available. On Linux, as glibc's search does, an error other than one
	## `execvp` steps past (missing, unreachable, refused, stale, timed out) —
	## a loop of links, say — ends the search.
	check_available! : Str => Bool
	check_available! = |command| {
		os = Env.platform!().os
		is_windows = 
			match os {
				WINDOWS => Bool.True
				_ => Bool.False
			}

		if has_separator(command, is_windows) {
			candidate_available!(path_utf8(command), os) == Found
		} else {
			path_value = 
				match Env.var!(OsStr.from_str("PATH")) {
					Ok(value) => value
					# Unset: the default search path spawning falls back to (execvp).
					Err(_) => OsStr.from_str(default_search_path)
				}

			# On Windows a name is tried as-is (so `git.exe` is found directly)
			# and with each `%PATHEXT%` extension appended (so `git` finds
			# `git.exe`). On Unix the name is used verbatim.
			extensions = if is_windows [""].concat(path_extensions!()) else [""]

			search_dirs!(path_dirs(path_value, is_windows), command, extensions, os)
		}
	}

	## Render a command configuration as a stable, escaped string.
	to_str : Cmd -> Str
	to_str = |cmd|
		"Cmd({ program: ${Str.inspect(cmd.program)}, args: ${Str.inspect(cmd.args)}, envs: ${Str.inspect(cmd.envs)}, clear_envs: ${Str.inspect(cmd.clear_envs)} })"

	## Customize command output for `Str.inspect`.
	to_inspect : Cmd -> Str
	to_inspect = |cmd| to_str(cmd)
}

flatten_arg_pairs : List((OsStr, OsStr)), List(OsStr), U64 -> List(OsStr)
flatten_arg_pairs = |pairs, acc, idx| {
	if idx >= pairs.len() {
		acc
	} else {
		match pairs.get(idx) {
			Ok(pair) =>
				flatten_arg_pairs(pairs, acc.append(pair.0).append(pair.1), idx + 1)
			Err(_) =>
				acc
			}
	}
}

## Run to completion with every stream inherited (D-S2-13).
waited! : Cmd => Try(Subprocess.ExitStatus, IOErr)
waited! = |cmd| {
	match Subprocess.spawn!(to_host_cmd(cmd), {}) {
		Ok(child) => child.wait!().map_err(|Io(err)| err)
		Err(Io(err)) => Err(err)
	}
}

## Run to completion with both outputs captured and stdin as given: `collect!`
## reads both to their ends, then waits (D-S2-13).
captured! : Cmd, [Null, Inherit] => Try(Subprocess.CmdOutputSuccess, [NonZeroExitCode(Subprocess.CmdOutputFailure), FailedToGetExitCode(IOErr)])
captured! = |cmd, stdin| {
	stdin_stdio = match stdin {
		Null => Null
		Inherit => Inherit
	}
	child = Subprocess.spawn!(to_host_cmd(cmd), { stdin: stdin_stdio, stdout: Pipe, stderr: Pipe }).map_err(|Io(err)| FailedToGetExitCode(err))?
	match child.collect!([]) {
		Ok({ status, stdout, stderr }) =>
			match CmdStatus.output_code(status) {
				0 => Ok({ stdout_bytes: stdout, stderr_bytes: stderr })
				exit_code => Err(NonZeroExitCode({ stdout_bytes: stdout, stderr_bytes: stderr, exit_code }))
			}
		Err(Io(err)) => {
			# Reaped even so: a run-to-completion call leaves no zombie behind.
			# Killed first: its other output is no longer read, and a child
			# blocked writing a full pipe would keep the wait from returning.
			_ = child.signal!(Kill)
			_ = child.wait!()
			Err(FailedToGetExitCode(err))
		}
		Err(NotPiped) => Err(FailedToGetExitCode(Other("stdin is not piped")))
	}
}

## The directories execvp searches when PATH is unset, on macOS and glibc
## alike; `check_available!` has to agree with what a spawn will find.
default_search_path : Str
default_search_path = "/usr/bin:/bin"

to_host_cmd : Cmd -> Subprocess.Cmd
to_host_cmd = |cmd| {
	args: cmd.args.map(OsStr.to_raw),
	clear_envs: cmd.clear_envs,
	envs: flatten_arg_pairs(cmd.envs, [], 0).map(OsStr.to_raw),
	program: OsStr.to_raw(cmd.program),
}

## A command name is a path, rather than a bare name, when it carries a separator.
has_separator : Str, Bool -> Bool
has_separator = |command, is_windows|
	command.contains("/") or (is_windows and command.contains("\\"))

## Split the raw `PATH` value into byte-preserving directory paths. On Unix an
## empty entry is the working directory, as execvp searches it (`PATH=/bin:`
## runs `./tool`); dropping it made `check_available!` disagree with a spawn.
## Windows' search does not read empty entries, so there they are dropped.
path_dirs : OsStr, Bool -> List(Path)
path_dirs = |path_value, is_windows|
	match OsStr.to_raw(path_value) {
		Utf8(str) =>
			Str.split_on(str, if is_windows ";" else ":")
				.keep_if(|segment| !is_windows or !Str.is_empty(segment))
				.map(|segment| if Str.is_empty(segment) { "." } else { segment })
				.map(Path.utf8)

		UnixBytes(bytes) =>
			split_on(bytes, if is_windows ';' else ':')
				.keep_if(|segment| !is_windows or !List.is_empty(segment))
				.map(|segment| if List.is_empty(segment) { ['.'] } else { segment })
				.map(Path.unix_bytes)

		WindowsU16s(u16s) =>
			split_on(u16s, if is_windows ';' else ':')
				.keep_if(|segment| !is_windows or !List.is_empty(segment))
				.map(|segment| if List.is_empty(segment) { ['.'] } else { segment })
				.map(Path.windows_u16s)
		}

## Split a list into segments on a separator element (segments may be empty).
split_on : List(a), a -> List(List(a)) where [a.is_eq : a, a -> Bool]
split_on = |items, sep| split_on_help(items, sep, [], [])

split_on_help : List(a), a, List(a), List(List(a)) -> List(List(a)) where [a.is_eq : a, a -> Bool]
split_on_help = |remaining, sep, current, acc|
	match remaining {
		[] => acc.append(current)
		[x, .. as rest] if x == sep => split_on_help(rest, sep, [], acc.append(current))
		[x, .. as rest] => split_on_help(rest, sep, current.append(x), acc)
	}

## The executable extensions to try on Windows, taken from `%PATHEXT%`.
path_extensions! : () => List(Str)
path_extensions! = ||
	match Env.var!(OsStr.from_str("PATHEXT")) {
		Ok(value) =>
			Str.split_on(OsStr.display(value), ";")
				.keep_if(|ext| !Str.is_empty(ext))
		Err(_) => [".com", ".exe", ".bat", ".cmd"]
	}

Os : [LINUX, MACOS, WINDOWS, OTHER(Str)]

## Search each directory for the command, returning on the first executable hit.
search_dirs! : List(Path), Str, List(Str), Os => Bool
search_dirs! = |dirs, command, extensions, os|
	match dirs {
		[] => Bool.False
		[dir, .. as rest] =>
			match search_extensions!(dir, command, extensions, os) {
				Found => Bool.True
				Stop => Bool.False
				Missing => search_dirs!(rest, command, extensions, os)
			}
		}

search_extensions! : Path, Str, List(Str), Os => [Found, Missing, Stop]
search_extensions! = |dir, command, extensions, os|
	match extensions {
		[] => Missing
		[ext, .. as rest] =>
			match candidate_available!(dir.join(command.concat(ext)), os) {
				Missing => search_extensions!(dir, command, rest, os)
				found_or_stop => found_or_stop
			}
		}

## Whether a specific candidate path is runnable: on Windows it must exist, on
## Unix this user must be allowed to execute it, which `can_execute!` answers
## for the target of a link and only for a regular file — so a directory, a
## link to one, and a FIFO are all refused there (D-S2-40 amended; the `/.`
## probe this used to make could push a long path past PATH_MAX, and an
## executable at 1022 bytes then read as missing while a spawn ran it).
## `Stop` is the Linux search ending on an error execvp does not step past.
candidate_available! : Path, Os => [Found, Missing, Stop]
candidate_available! = |candidate, os|
	match os {
		WINDOWS =>
			match Path.exists!(candidate) {
				Ok(Bool.True) => if windows_not_directory!(candidate) { Found } else { Missing }
				_ => Missing
			}
		_ =>
			match Subprocess.can_execute!(Path.to_os_str(candidate)) {
				Ok({}) => Found
				# What glibc's execvp steps past; macOS keeps searching on
				# anything, so only Linux stops.
				Err(Io(NotFound)) | Err(Io(NotADirectory)) | Err(Io(PermissionDenied)) => Missing
				Err(Io(e)) => if os == LINUX and !steps_past(e) { Stop } else { Missing }
			}
	}

## ESTALE, ENODEV and ETIMEDOUT: glibc's `__execvpe` keeps searching on these
## as well, and `IOErr` has no variant for any of them.
steps_past : IOErr -> Bool
steps_past = |err| match err {
	Other(message) => List.any(["(os error 116)", "(os error 19)", "(os error 110)"], |code| Str.contains(message, code))
	_ => Bool.False
}

## Windows has no `can_execute!`: there, a candidate that exists is runnable
## unless it is a directory. These are filesystem calls, so a Windows build
## wired to `fs-confined` would answer `PermissionDenied` for every candidate
## outside the root and report every program missing — what the Unix arm did
## before round 10. Windows needs its own unconfined leaf before this runs.
windows_not_directory! : Path => Bool
windows_not_directory! = |candidate|
	match Path.is_dir!(candidate) {
		Ok(is_dir) => !is_dir
		Err(_) => Bool.False
	}

## Inspection is escaped and includes the full immutable command configuration.
expect {
	cmd = Cmd.new_str("echo\nnext")
		.arg_str("hello world")
		.env_str("NAME", "Roc")
		.clear_envs()

	Str.inspect(cmd) == "Cmd({ program: OsStr.utf8(\"echo\\nnext\"), args: [OsStr.utf8(\"hello world\")], envs: [(OsStr.utf8(\"NAME\"), OsStr.utf8(\"Roc\"))], clear_envs: True })"
}

## A name is a path only when it carries a separator for the current platform.
expect has_separator("git", Bool.False) == Bool.False
expect has_separator("./git", Bool.False) == Bool.True
expect has_separator("a\\b", Bool.False) == Bool.False
expect has_separator("a\\b", Bool.True) == Bool.True

## Splitting keeps every segment, including a trailing empty one after a separator.
expect split_on([1.U8, 2, 58, 3], 58) == [[1, 2], [3]]
expect split_on([59.U16, 1, 59], 59) == [[], [1], []]

## PATH splitting preserves raw bytes, including non-UTF-8 directory entries.
expect {
	# "/a" ++ ":" ++ "/<0xFF>b" — the 0xFF byte is not valid UTF-8.
	path = OsStr.unix_bytes([0x2F, 0x61, 0x3A, 0x2F, 0xFF, 0x62])
	path_dirs(path, Bool.False) == [Path.unix_bytes([0x2F, 0x61]), Path.unix_bytes([0x2F, 0xFF, 0x62])]
}

## The UTF-8 PATH representation splits the same way.
expect path_dirs(OsStr.utf8("/a:/b"), Bool.False) == [path_utf8("/a"), path_utf8("/b")]

## An empty Unix PATH entry (a stray or trailing separator) is the working
## directory, as execvp reads it; on Windows it is dropped.
expect path_dirs(OsStr.utf8("/a::/b:"), Bool.False) == [path_utf8("/a"), path_utf8("."), path_utf8("/b"), path_utf8(".")]
expect path_dirs(OsStr.utf8("C;;D;"), Bool.True) == [path_utf8("C"), path_utf8("D")]

## Windows PATH splits on ';' and preserves UTF-16 units.
expect {
	path = OsStr.windows_u16s([0x43, 0x3B, 0x44])
	path_dirs(path, Bool.True) == [path_windows_u16s([0x43]), path_windows_u16s([0x44])]
}

## Migration bridge (R8): basic-cli's Path has no `utf8`/`windows_u16s`
## constructors (seahaven's do); both are one `from_raw` away.
path_utf8 : Str -> Path
path_utf8 = |s| Path.from_raw(Utf8(s))
path_windows_u16s : List(U16) -> Path
path_windows_u16s = |units| Path.from_raw(WindowsU16s(units))
