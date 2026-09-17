# Shared by the tests/*/test.sh suites. `trantor test` hands each script
# TRANTOR, ROC, PKG, TMP, DEPS (the package and its dev-deps) and DEV_DEPS.
# bash 3.2 compatible.
set -euo pipefail

# Physical, because a child's `pwd` reports the resolved path and macOS's /var
# is a symlink to /private/var.
TMP=$(cd "$TMP" && pwd -P)
PIDS=""
trap 'for p in $PIDS; do kill "$p" 2>/dev/null || true; done' EXIT

# A consumer of this package at $TMP/myapp: trantor-cli and trantor-process,
# the two lines an app that runs commands names.
new_project() {
	mkdir -p "$TMP/myapp/app"
	printf '[world]\nname = "myapp"\n\n[deps]\n%s' "$DEPS" > "$TMP/myapp/world.toml"
}

# build_app SOURCE OUT — build SOURCE as the project's bin/OUT.
build_app() {
	cp "$1" "$TMP/myapp/app/main.roc"
	local out
	if ! out=$("$TRANTOR" build "$TMP/myapp" --app app --out "$2" 2>&1); then
		echo "FAIL: build $2" >&2; echo "$out" | tail -20 >&2; exit 1
	fi
}

bin() { echo "$TMP/myapp/target/trantor/myapp/bin/$1"; }

# `exec { $ARGV[0] } @ARGV`, not `exec @ARGV`: with one argument perl splits it
# on whitespace or hands it to /bin/sh, and a failed exec exited 0 silently.
capped() { local secs=$1; shift; perl -e 'alarm shift; exec { $ARGV[0] } @ARGV or die "capped: exec $ARGV[0]: $!\n"' "$secs" "$@"; }
