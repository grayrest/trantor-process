# Spawning a child with its streams piped, redirected or inherited, and
# watching it end.
#
# Each case exercises a way the old run-to-completion calls could not be used:
# 200 KB streamed from a pipe as it arrives; both outputs piped past a pipe
# buffer together with 100 KB of input, which deadlocks unless all three move at
# once; both outputs merged into a file through one descriptor, and a file as
# stdin, with no shell; an output sent to a file stream; stdin written by hand
# and closed; a running child seen by try_wait!, then signalled and reported as
# Signaled rather than a code; NotPiped for a stream that is not; a missing
# program as NotFound; the same through Cmd.spawn!. The last case holds
# review regressions: stdout! as a child's last use (a use-after-free), a child
# that exits unread (SIGPIPE killed the app), a writer's descriptor handed to a
# child (the child overwrote its bytes), a signal after reaping, and input after
# close_stdin! (silently dropped), and `yes` writing into another child's stdin
# pipe dying of SIGPIPE when that child exits.
source ../lib.sh
new_project
S="$TMP/spawn"
mkdir -p "$S"
echo lower > "$S/input.txt"
build_app app.roc spawn
got=$(cd "$S" && capped 60 "$(bin spawn)" </dev/null) || { echo "FAIL: the spawn app did not finish"; exit 1; }
want="200000,exited0 100000/100000,True,exited0 out+err+exited0,LOWER via-stream by hand,exited0 running,signaled15,True notpiped,notpiped,exited7 notfound via-cmd,spawnfailed-named last,exited0,head,child,tail,refused,notpiped,sigpiped,refused,rc=0"
[[ "$got" == "$want" ]] || {
	echo "FAIL: outcomes were '$got'"
	echo "                 want '$want'"
	echo "      (streamed collected descriptors to-stream hand-fed signalled not-piped missing cmd-spawn review-regressions)"; exit 1; }
# Again with this process's stdin closed: the driver opens fd 0 on /dev/null
# first, or a pipe landed there and every child's stdin was closed at exec;
# and that /dev/null must not be close-on-exec, or a child inheriting stdin
# finds it closed.
rm -f "$S/merged.txt" "$S/streamed.txt" "$S/shared.txt"
# Closed inside the timeout wrapper: perl opens a file on a free fd 0 before
# exec, so `capped … <&-` never reached the app with stdin closed.
closed=$(cd "$S" && capped 60 sh -c 'exec "$0" <&-' "$(bin spawn)") || { echo "FAIL: the spawn app did not finish with stdin closed"; exit 1; }
[[ "$closed" == "$want" ]] || { echo "FAIL: with stdin closed, outcomes were '$closed'"; echo "                                  want '$want'"; exit 1; }
# A redirect fd is borrowed: handing the raw leaf fd 1 must leave the app's
# stdout open, where the host once closed whatever number it was given.
borrowed=$(cd "$S" && capped 60 "$(bin spawn)" borrowed | tr '\n' ' ') || { echo "FAIL: the borrowed-fd run did not finish"; exit 1; }
[[ "$borrowed" == "child parent " ]] || { echo "FAIL: after lending fd 1 to a child, stdout held '$borrowed', want 'child parent '"; exit 1; }
# try_wait! does not close stdin, so a child reading its stdin pipe is still
# Running; wait!, which closes it, ends the same child at once.
polled=$(cd "$S" && capped 60 "$(bin spawn)" poll poll) || { echo "FAIL: the poll run did not finish"; exit 1; }
[[ "$polled" == "running exited0" ]] || { echo "FAIL: polling a stdin-reading child gave '$polled', want 'running exited0'"; exit 1; }
# The raw spawn and its fd numbers are wired but not exported: an app naming
# SubprocessRaw must not build.
cat > "$TMP/myapp/app/main.roc" <<'RAW'
app [main!] { pf: platform "../target/trantor/myapp/platform/main.roc" }

import pf.OsStr exposing [OsStr]
import pf.SubprocessRaw

main! : List(OsStr) => Try({}, _)
main! = |_args| Ok({})
RAW
if "$TRANTOR" build "$TMP/myapp" --app app --out raw >/dev/null 2>&1; then
	echo "FAIL: an app imported SubprocessRaw, which is not an export"; exit 1
fi
echo "ok: a child's streams pipe, redirect to files and streams, and close; it is waited on, polled and signalled"
