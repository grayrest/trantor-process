# Cmd's run-to-completion functions through real processes, over spawn!.
#
# They kept basic-cli's results when rebuilt on spawn!, and until this only the
# pure status mappings were tested: a non-zero exit with both outputs, a signal
# death as -1 in exec_output!, the bytes variant, inherited versus null stdin,
# exec_exit_code!'s signal message, exec_status!'s -15, and exec!'s ExecFailed.
source ../lib.sh
new_project
build_app app.roc cmd
# From $TMP: the app makes and removes a directory beside where it runs, and
# an interrupted run must not leave one in the source tree.
got=$(cd "$TMP" && printf fed | capped 60 "$(bin cmd)") || { echo "FAIL: the cmd app did not finish"; exit 1; }
want="3:out:err -1 [97, 98] fed empty child_was_killed_by_signal_15 -15 4 True cwd-gone"
[[ "$got" == "$want" ]] || {
	echo "FAIL: outcomes were '$got'"
	echo "                 want '$want'"
	echo "      (nonzero signal-output bytes inherit-stdin null-stdin exit_code-signal status-signal exec check-available cwd-removed)"; exit 1; }
# With PATH unset, spawning falls back to the default search path, and
# check_available! must say what a spawn will find.
unset_path=$(cd "$TMP" && printf fed | capped 60 env -u PATH "$(bin cmd)") || { echo "FAIL: the cmd app did not finish with PATH unset"; exit 1; }
[[ "$unset_path" == "$want" ]] || { echo "FAIL: with PATH unset, outcomes were '$unset_path'"; exit 1; }
# An empty PATH entry is the working directory to a spawn, so it must be to
# check_available! too.
# A link is judged by what it leads to, as the spawn judges it: a link's own
# mode bits made a dangling link in PATH available. And by whether this user may
# execute it: any execute bit made a group-only tool available to its owner.
mkdir -p "$TMP/tools/a-dir"; printf '#!/bin/sh\necho local-tool\n' > "$TMP/tools/local-tool"; chmod 755 "$TMP/tools/local-tool"
printf '#!/bin/sh\necho noexec\n' > "$TMP/tools/plain"; chmod 644 "$TMP/tools/plain"
printf '#!/bin/sh\necho group-only\n' > "$TMP/tools/group-only"; chmod 654 "$TMP/tools/group-only"
ln -s missing "$TMP/tools/dangling"; ln -s plain "$TMP/tools/noexec-link"; ln -s local-tool "$TMP/tools/tool-link"; ln -s a-dir "$TMP/tools/dir-link"
# A path close to PATH_MAX: appending "/." to probe for a directory pushed it
# past the limit, and the tool read as missing while a spawn ran it.
deep="$TMP/deep"
# The candidate lands just under PATH_MAX (1024 on macOS): with "/." appended
# to probe for a directory it went over, and stat then failed.
target=1012
while (( ${#deep} + 61 <= target )); do deep="$deep/$(printf 'a%.0s' $(seq 60))"; done
rem=$(( target - ${#deep} - 1 ))
(( rem <= 0 )) || deep="$deep/$(printf 'a%.0s' $(seq $rem))"
mkdir -p "$deep"; printf '#!/bin/sh\necho deep\n' > "$deep/deep-tool"; chmod 755 "$deep/deep-tool"
checked=$(cd "$TMP/tools" && capped 60 env "PATH=/nope:$deep:" "$(bin cmd)" check) || { echo "FAIL: the cmd app did not finish its PATH check"; exit 1; }
want_checked="local-tool:True:local-tool dangling:False:did-not-run noexec-link:False:did-not-run tool-link:True:local-tool dir-link:False:did-not-run group-only:False:did-not-run deep-tool:True:deep"
[[ "$checked" == "$want_checked" ]] || { echo "FAIL: with PATH=/nope: from the tools directory, got '$checked'"; echo "                                                  want '$want_checked'"; exit 1; }
echo "ok: Cmd's exec functions report codes, outputs, signals and errors as basic-cli does"
