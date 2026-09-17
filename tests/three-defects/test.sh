# Three things that reported success, or reported the wrong failure.
#
# `File.Reader.read_line!` split any line past its 1MiB cap into chunks a caller
# cannot tell from real lines. `Env.var!` mapped every `std::env::var` error to
# `VarNotFound`, so a variable SET with a non-UTF-8 value read exactly like one
# never set. `Cmd.exec_exit_code!` returned `Ok(-1)` for a child killed by a
# signal. Each is asserted next to the case that always worked, so a version
# that failed everything would not pass.
source ../lib.sh
new_project
mkdir -p "$TMP/lines"
python3 -c "open('$TMP/lines/long.txt','w').write('a'*2000000 + chr(10) + 'short' + chr(10))"
printf 'one\ntwo\n' > "$TMP/lines/ok.txt"
build_app app.roc three
three=$(cd "$TMP/lines" && env "BADVAR=$(printf '\xff\xfe')" "$(bin three)") \
	|| { echo "FAIL: the three-defect app did not run"; exit 1; }
[[ "$three" == "eof2 toolong bytes notfound err -15 3" ]] || {
	echo "FAIL: outcomes were '$three', want 'eof2 toolong bytes notfound err -15 3'"
	echo "       (short-file long-file set-nonutf8 unset signal-exit_code signal-status plain-exit)"; exit 1; }
echo "ok: a long line, a non-UTF-8 variable and a signal death each report themselves"
