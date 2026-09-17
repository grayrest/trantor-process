# A RELATIVE userland cwd means the same directory to file ops and to children,
# and a cwd that cannot be one is refused.
#
# A relative one was stored as given, then joined onto preopen 0 for file ops
# (so "sub" meant /sub) while the subprocess layer handed the same string to
# `Command::current_dir`, where the OS resolved it against the PROCESS cwd. Both
# sides are asserted, and compared to each other rather than to a literal.
source ../lib.sh
new_project
mkdir -p "$TMP/cwdcheck/sub"
echo "INSIDE-SUB" > "$TMP/cwdcheck/sub/marker.txt"
echo "TOPLEVEL"   > "$TMP/cwdcheck/marker.txt"
build_app app.roc cwd
cwdout=$(cd "$TMP/cwdcheck" && "$(bin cwd)") || { echo "FAIL: the cwd app did not run"; exit 1; }
read -r seen child missing file <<<"$cwdout"
[[ "$seen" == "INSIDE-SUB" ]] || { echo "FAIL: a file op under a relative cwd read '$seen', want 'INSIDE-SUB'"; exit 1; }
[[ "$child" == "$TMP/cwdcheck/sub" ]] || { echo "FAIL: the child ran in '$child', want '$TMP/cwdcheck/sub'"; exit 1; }
[[ "$missing" == "refused" ]] || { echo "FAIL: set_cwd! accepted a path that does not exist"; exit 1; }
[[ "$file" == "refused" ]] || { echo "FAIL: set_cwd! accepted a file as a working directory"; exit 1; }
echo "ok: a relative cwd means one directory to file ops and children alike, and a bad one is refused"
