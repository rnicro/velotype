#!/usr/bin/env bash
set -euo pipefail
trap 'status=$?; printf "test-wayland-patch.sh: failure at line %s: %s (exit %s)\n" "$LINENO" "$BASH_COMMAND" "$status" >&2; exit "$status"' ERR

repo_root="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
template="${repo_root}/srcpkgs/velotype/template"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fake_bin="${tmp}/bin"
cargo_home="${tmp}/cargo"
wrksrc="${tmp}/work"
mkdir -p "$fake_bin" "$cargo_home" "$wrksrc" "${tmp}/destdir/usr"

cat > "$wrksrc/Cargo.toml" <<'TOML'
[dependencies]
gpui = { package = "gpui-pre", version = "=0.3.9" }
gpui_platform = { package = "gpui-pre-platform", version = "=0.3.9", features = ["font-kit", "x11", "wayland", "runtime_shaders"] }
TOML
cat > "$wrksrc/Cargo.lock" <<'LOCK'
version = 4

[[package]]
name = "velotype"
version = "0.7.8"
dependencies = [
 "gpui-pre",
 "gpui-pre-platform",
]

[[package]]
name = "gpui-pre-platform"
version = "0.3.9"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
LOCK

cat > "${tmp}/cargo-tree-good.txt" <<'TREE'
velotype v0.7.8
├── gpui-pre-platform v0.3.9
│   ├── gpui-pre-platform feature "font-kit"
│   ├── gpui-pre-platform feature "runtime_shaders"
│   └── gpui-pre-platform feature "wayland"
└── wayland-client v0.31.15
TREE
cat > "${tmp}/cargo-tree-x11.txt" <<'TREE'
velotype v0.7.8
├── gpui-pre-platform v0.3.9
│   ├── gpui-pre-platform feature "wayland"
│   └── gpui-pre-platform feature "x11"
└── xkbcommon feature "x11"
TREE

cat > "$fake_bin/cargo" <<'CARGO'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${CARGO_TEST_LOG:?}"
case "${1:-}:${2:-}" in
  update:*)
    [[ "${CARGO_TEST_MODE:-success}" != update-failure ]] || exit 74
    exit 0
    ;;
  fetch:*)
    [[ "${CARGO_TEST_MODE:-success}" != fetch-failure ]] || exit 73
    exit 0
    ;;
  tree:*)
    cat "${CARGO_TEST_TREE:?}"
    ;;
  auditable:build)
    case " ${CFLAGS:-} " in *" -march=skylake "*) ;; *) exit 99 ;; esac
    case " ${CXXFLAGS:-} " in *" -march=skylake "*) ;; *) exit 99 ;; esac
    case " ${RUSTFLAGS:-} " in *" -C target-cpu=skylake "*) ;; *) exit 99 ;; esac
    [[ "${CARGO_PROFILE_RELEASE_OPT_LEVEL:-}" == 3 ]] || exit 99
    [[ "${RUSTC_WRAPPER:-}" == sccache ]] || exit 99
    [[ "${SCCACHE_DIR:-}" == "${CARGO_HOME}/sccache" ]] || exit 99
    [[ "${SCCACHE_CACHE_SIZE:-}" == 2G ]] || exit 99
    [[ "${CARGO_BUILD_JOBS:-}" == 6 ]] || exit 99
    [[ "${CARGO_TEST_MODE:-success}" == success ]] && exit 0
    exit 71
    ;;
  *)
    echo "unexpected Cargo invocation: $*" >&2
    exit 64
    ;;
esac
CARGO
chmod +x "$fake_bin/cargo"

export PATH="${fake_bin}:${PATH}"
export CARGO_HOME="$cargo_home"
export XBPS_TARGET_MACHINE=x86_64-musl
export XBPS_TARGET_LIBC=musl
export RUST_TARGET=x86_64-unknown-linux-musl
export CFLAGS=
export CXXFLAGS=
export RUSTFLAGS=
unset CARGO_PROFILE_RELEASE_OPT_LEVEL
export CARGO_BUILD_JOBS=6
export DESTDIR="${tmp}/destdir"
export configure_args=
export make_build_args=
export make_install_args=
export CARGO_TEST_TREE="${tmp}/cargo-tree-good.txt"
export CARGO_TEST_LOG="${tmp}/cargo-commands.log"
: > "$CARGO_TEST_LOG"

source "$template"
wrksrc="$tmp/work"

# The package patch must disable platform defaults and remove the X11 feature.
post_patch
post_patch
wayland_platform='gpui_platform = { package = "gpui-pre-platform", version = "=0.3.9", default-features = false, features = ["font-kit", "wayland", "runtime_shaders"] }'
grep -Fxq "$wayland_platform" "$wrksrc/Cargo.toml"
grep -Fq -- '-p gpui-pre-platform@0.3.9' "$CARGO_TEST_LOG" || {
  echo "post_patch did not target Cargo.lock refresh to gpui-pre-platform 0.3.9" >&2
  exit 1
}
export CARGO_TEST_MODE=update-failure
if post_patch >/dev/null 2>&1; then
  echo "post_patch ignored a failed targeted Cargo.lock update" >&2
  exit 1
fi
export CARGO_TEST_MODE=success
if grep -Fq 'features = ["font-kit", "x11", "wayland", "runtime_shaders"]' "$wrksrc/Cargo.toml"; then
  echo "GPUI platform X11 feature was not removed" >&2
  exit 1
fi

# Confirm feature-graph validation accepts a Wayland-only graph and rejects X11.
_velotype_assert_wayland_only
export CARGO_TEST_TREE="${tmp}/cargo-tree-x11.txt"
if _velotype_assert_wayland_only >/dev/null 2>&1; then
  echo "Wayland-only assertion accepted an X11-enabled feature graph" >&2
  exit 1
fi
export CARGO_TEST_TREE="${tmp}/cargo-tree-good.txt"

# Build flags should target Skylake and use runner-aware parallelism.
_velotype_set_build_env
[[ "$CARGO_PROFILE_RELEASE_OPT_LEVEL" == 3 ]]
[[ "$RUSTC_WRAPPER" == sccache ]]
[[ "$SCCACHE_DIR" == "$CARGO_HOME/sccache" ]]
[[ "$SCCACHE_CACHE_SIZE" == 2G ]]
[[ "$CARGO_BUILD_JOBS" -eq 6 ]]
unset CARGO_BUILD_JOBS
_velotype_set_build_env
expected_jobs="$(_velotype_calculate_cargo_jobs)"
[[ "$CARGO_BUILD_JOBS" =~ ^[1-9][0-9]*$ ]] || {
  echo "automatic Cargo parallelism did not produce a positive job count" >&2
  exit 1
}
[[ "$CARGO_BUILD_JOBS" -eq "$expected_jobs" ]] || {
  echo "Cargo parallelism did not match the CPU/memory-aware limit" >&2
  exit 1
}
[[ "$CARGO_BUILD_JOBS" -le "$(nproc)" ]] || {
  echo "Cargo parallelism exceeded the runner's available CPUs" >&2
  exit 1
}
export CARGO_BUILD_JOBS=6

# Mock a successful build; the installed executable must be copied, not rebuilt.
export CARGO_TEST_MODE=success
if ! do_build; then
  echo "mocked Cargo build unexpectedly failed" >&2
  exit 1
fi
grep -Fq 'auditable build' "$CARGO_TEST_LOG"
built_binary="${wrksrc}/target/${RUST_TARGET}/release/velotype"
mkdir -p "$(dirname "$built_binary")"
printf '#!/bin/sh\nexit 0\n' > "$built_binary"
chmod 0755 "$built_binary"
installed_binary="${DESTDIR}/usr/bin/velotype"
: > "$CARGO_TEST_LOG"
do_install
[[ -x "$installed_binary" ]]
cmp -s "$built_binary" "$installed_binary"
[[ ! -s "$CARGO_TEST_LOG" ]] || {
  echo "do_install unexpectedly invoked Cargo" >&2
  cat "$CARGO_TEST_LOG" >&2
  exit 1
}

# If the resolved graph re-enables X11, the actual compile command must not run.
export CARGO_TEST_TREE="${tmp}/cargo-tree-x11.txt"
: > "$CARGO_TEST_LOG"
if do_build; then
  echo "package build accepted an X11-enabled feature graph" >&2
  exit 1
fi
if grep -Fq 'auditable build' "$CARGO_TEST_LOG"; then
  echo "Cargo build ran despite an X11-enabled feature graph" >&2
  exit 1
fi

# A fetch error is propagated without starting the build.
export CARGO_TEST_TREE="${tmp}/cargo-tree-good.txt"
export CARGO_TEST_MODE=fetch-failure
: > "$CARGO_TEST_LOG"
if do_build; then
  echo "expected mocked Cargo fetch to fail" >&2
  exit 1
else
  status=$?
  [[ "$status" -eq 73 ]] || { echo "unexpected fetch status: $status" >&2; exit 1; }
fi
if grep -Fq 'auditable build' "$CARGO_TEST_LOG"; then
  echo "Cargo build ran after dependency fetch failed" >&2
  exit 1
fi

echo "Wayland-only feature patch and build lifecycle tests passed"
