# check_available! answers for a world whose filesystem is confined.
#
# A spawn is not confined (D-S2-19), and neither is the executable check
# (D-S2-43) — but the directory exclusion went through the filesystem, which
# refused every path outside the root, so `check_available!` reported every
# program missing while spawning it worked.
source ../lib.sh
new_project
printf '\n[wiring]\nfs = "fs-confined"\n' >> "$TMP/myapp/world.toml"
build_app app.roc confined
got=$(cd "$TMP" && capped 60 "$(bin confined)") || { echo "FAIL: the confined app did not finish"; exit 1; }
[[ "$got" == "True ran" ]] || { echo "FAIL: with fs-confined wired, got '$got', want 'True ran'"; exit 1; }
echo "ok: a confined filesystem does not make every program look missing"
