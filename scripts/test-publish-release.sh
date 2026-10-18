#!/usr/bin/env bash
set -euo pipefail
repo_root="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fake_bin="$tmp/bin"
state="$tmp/state"
dist="$tmp/dist"
mkdir -p "$fake_bin" "$state/assets" "$dist"
log="$tmp/gh.log"
touch "$log"
export GH_STATE="$state" GH_LOG="$log"
export VERSION=0.7.8
export UPSTREAM_COMMIT=a61c71955c6104fc5d647088b5957da6d59149ca
export RELEASE_COMMIT=1111111111111111111111111111111111111111
export GH_REPO=test/velotype GH_TOKEN=test-token

cat > "$fake_bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$GH_LOG"
[[ "${1:-}" == release ]] || exit 64
subcommand="${2:-}"
tag="${3:-}"
case "$subcommand" in
  view)
    [[ -f "$GH_STATE/release-exists" ]] || exit 1
    case " $* " in
      *" --json assets "*)
        shopt -s nullglob
        for path in "$GH_STATE/assets"/*; do [[ -f "$path" ]] && basename "$path"; done
        ;;
      *" --json isDraft "*) printf 'false\n' ;;
      *" --json url "*) printf 'https://github.com/test/velotype/releases/tag/%s\n' "$tag" ;;
      *" --json tagName "*) printf '%s\n' "$tag" ;;
      *) echo "unexpected mocked gh release view: $*" >&2; exit 64 ;;
    esac
    ;;
  create)
    shift 3
    while (($#)); do
      case "$1" in
        --title|--notes-file|--target) shift 2 ;;
        --latest) shift ;;
        *)
          [[ -f "$1" ]] || { echo "missing release asset: $1" >&2; exit 66; }
          cp "$1" "$GH_STATE/assets/$(basename "$1")"
          shift
          ;;
      esac
    done
    touch "$GH_STATE/release-exists"
    ;;
  download)
    shift 3
    patterns=()
    dest=""
    while (($#)); do
      case "$1" in
        --pattern) patterns+=("$2"); shift 2 ;;
        --dir) dest="$2"; shift 2 ;;
        *) echo "unexpected mocked download arg: $1" >&2; exit 64 ;;
      esac
    done
    [[ -n "$dest" ]] || exit 64
    mkdir -p "$dest"
    for pattern in "${patterns[@]}"; do
      [[ -s "$GH_STATE/assets/$pattern" ]] || { echo "missing mocked asset: $pattern" >&2; exit 1; }
      cp "$GH_STATE/assets/$pattern" "$dest/"
    done
    ;;
  delete-asset)
    asset="${4:-}"
    [[ -n "$asset" && -f "$GH_STATE/assets/$asset" ]] || { echo "missing mocked asset to delete: $asset" >&2; exit 1; }
    rm "$GH_STATE/assets/$asset"
    ;;
  upload)
    shift 3
    for asset in "$@"; do
      [[ -f "$asset" ]] || { echo "missing upload asset: $asset" >&2; exit 66; }
      cp "$asset" "$GH_STATE/assets/$(basename "$asset")"
    done
    ;;
  edit) [[ -f "$GH_STATE/release-exists" ]] || exit 1 ;;
  *) echo "unexpected mocked gh command: $*" >&2; exit 64 ;;
esac
GH
chmod +x "$fake_bin/gh"
export PATH="$fake_bin:$PATH"

make_package() {
  local revision="$1"
  local contents="$2"
  rm -f "$dist"/*.xbps
  printf '%s\n' "$contents" > "$dist/velotype-${VERSION}_${revision}.x86_64-musl.xbps"
  export REVISION="$revision"
}
publish() { bash "$repo_root/scripts/publish-release.sh" "$dist"; }
assert_package_only() {
  local count
  count="$(find "$state/assets" -maxdepth 1 -type f | wc -l)"
  [[ "$count" -eq 1 ]] || { echo "expected one release asset, found $count" >&2; find "$state/assets" -type f >&2; exit 1; }
  [[ -s "$state/assets/$1" ]] || { echo "missing package asset $1" >&2; exit 1; }
  for sidecar in SHA256SUMS SHA512SUMS BUILD-INFO.txt; do
    [[ ! -e "$state/assets/$sidecar" ]] || { echo "unexpected release sidecar $sidecar" >&2; exit 1; }
  done
}

# A new release has a version-only tag and the package as its sole asset.
make_package 2 "stable package bytes revision 2"
publish
[[ -f "$state/release-exists" ]]
assert_package_only "velotype-0.7.5_2.x86_64-musl.xbps"
grep -Fq 'release create 0.7.5' "$log" || { echo "release tag was not version-only" >&2; exit 1; }
if grep -Fq 'release create velotype-0.7.5_2' "$log"; then
  echo "release tag incorrectly included the XBPS revision" >&2
  exit 1
fi

# Older releases may have sidecars; the next reconciliation removes them.
for sidecar in SHA256SUMS SHA512SUMS BUILD-INFO.txt; do printf 'legacy sidecar\n' > "$state/assets/$sidecar"; done
publish
assert_package_only "velotype-0.7.5_2.x86_64-musl.xbps"
grep -Fq 'release edit 0.7.5' "$log" || { echo "idempotent run did not reconcile the release" >&2; exit 1; }

# Higher revisions replace older packages with a single current asset.
export RELEASE_COMMIT=2222222222222222222222222222222222222222
make_package 3 "stable package bytes revision 3"
publish
assert_package_only "velotype-0.7.5_3.x86_64-musl.xbps"
[[ ! -e "$state/assets/velotype-0.7.5_2.x86_64-musl.xbps" ]]

# Changed bytes without a revision bump must fail and preserve the published package.
make_package 3 "different bytes without revision bump"
if publish >"$tmp/reproducibility.log" 2>&1; then
  echo "release accepted different bytes for an existing revision" >&2
  exit 1
fi
grep -Fq 'Package bytes changed without a version/revision change' "$tmp/reproducibility.log" || {
  cat "$tmp/reproducibility.log" >&2
  exit 1
}
grep -Fq 'stable package bytes revision 3' "$state/assets/velotype-0.7.5_3.x86_64-musl.xbps"

# Revision downgrades must fail without mutating the current asset.
make_package 2 "rollback package bytes"
if publish >"$tmp/downgrade.log" 2>&1; then
  echo "release accepted a lower package revision" >&2
  exit 1
fi
grep -Fq 'Refusing revision downgrade' "$tmp/downgrade.log" || {
  cat "$tmp/downgrade.log" >&2
  exit 1
}
assert_package_only "velotype-0.7.5_3.x86_64-musl.xbps"
echo "package-only versioned release tests passed"
