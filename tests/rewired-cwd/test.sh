# The userland cwd when a world REWIRES it: `[wiring] cwd = "my-cwd"` puts the
# slot on the world's own component, and every reader must still find it.
#
# `subprocess-host` used to declare `trantor__cwd_host__get` by hand and call
# it, naming trantor-cli's DEFAULT component rather than the `cwd` interface
# (the extern D-S2-19 left behind). A rewired world still linked, because
# `cwd-host` is compiled either way — it was simply never written to, so the
# child ran in the process's directory while file ops saw the userland one, and
# a relative program name was checked against the wrong directory too. The
# wiring is only visible from Roc, so the Roc layer reads `Cwd.get!` and hands
# the value to the host.
source ../lib.sh
new_project
mkdir -p "$TMP/cwdcheck/sub"
echo "INSIDE-SUB" > "$TMP/cwdcheck/sub/marker.txt"
echo "TOPLEVEL"   > "$TMP/cwdcheck/marker.txt"
printf '#!/bin/sh\nexit 0\n' > "$TMP/cwdcheck/sub/toolx"
chmod +x "$TMP/cwdcheck/sub/toolx"

# The world's own `cwd` component: cwd-host's slot under another name, so the
# only thing under test is WHICH component the layers reach.
mkdir -p "$TMP/myapp/components/my-cwd/src"
cat > "$TMP/myapp/components/my-cwd/Cargo.toml" <<'EOF'
[package]
name = "my-cwd"
version = "0.0.0"
edition = "2021"
publish = false
[lib]
crate-type = ["staticlib", "rlib"]
[dependencies]
trantor-abi = "0.0.0"
EOF
cat > "$TMP/myapp/components/my-cwd/src/lib.rs" <<'EOF'
//! This world's own `cwd`: one process-global Str slot, as cwd-host keeps one.
use trantor_abi as abi;
use abi::RocStr;
use std::sync::Mutex;

static SLOT: Mutex<String> = Mutex::new(String::new());

/// hosted `Cwd.set! : Str => {}`
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__my_cwd__set(value: RocStr) {
    *SLOT.lock().unwrap() = value.as_str().to_string();
    unsafe { value.decref(abi::host()); } // owned arg (B0)
}

/// hosted `Cwd.get! : {} => Str`
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__my_cwd__get() -> RocStr {
    RocStr::from_str(&SLOT.lock().unwrap(), abi::host())
}
EOF
printf '\n[components.my-cwd]\nkind = "host"\nlang = "rust"\nexports = ["cwd"]\n\n[wiring]\ncwd = "my-cwd"\n' >> "$TMP/myapp/world.toml"

build_app app.roc rewired
out=$(cd "$TMP/cwdcheck" && capped 60 "$(bin rewired)") || { echo "FAIL: the rewired-cwd app did not run"; exit 1; }
read -r seen child tool <<<"$out"
[[ "$seen" == "INSIDE-SUB" ]] || { echo "FAIL: a file op under the rewired cwd read '$seen', want 'INSIDE-SUB'"; exit 1; }
[[ "$child" == "$TMP/cwdcheck/sub" ]] || { echo "FAIL: the child ran in '$child', want '$TMP/cwdcheck/sub' — the host read a cwd slot this world does not use"; exit 1; }
[[ "$tool" == "True" ]] || { echo "FAIL: check_available! answered '$tool' for ./toolx under the rewired cwd, want 'True'"; exit 1; }
echo "ok: a world that rewires cwd gets one directory for file ops, children and the executable check"
