# velotype

Void Linux `x86_64-musl` package for [Velotype](https://github.com/manyougz/velotype), a native Rust/GPUI Markdown editor.

This package pins Velotype `0.7.8` to upstream commit `07a24a9b5b953539dede8e61a1f7d9d0adbba590` and verifies the source archive SHA-256 (`75c190c578b8dda567a6eca8ed0ad1568cd714b7f90d1966e98b2141608a5d48`) before building.

## Repository workflow

Commit repository maintenance directly to the configured default branch (`main` currently; use `master` only if it is actually the default). Do not create feature branches or pull requests for routine package updates. Batch related edits into one commit to avoid redundant, cancelled CI builds. Before a release, verify the upstream commit and source SHA-256, run package-validation tests, and confirm the real `xbps-src` build succeeds; never treat a test-only run as a package-build pass.

## Target hardware

The binary is specialized for the Intel Core i3-6100U (Skylake): C/C++ components use `-O2 -march=skylake`, and Rust uses `-C target-cpu=skylake`. The package overrides upstream's size-focused Rust `opt-level = "s"` with `CARGO_PROFILE_RELEASE_OPT_LEVEL=3` for higher runtime optimization in parsing, text processing, and interactive UI paths. Full LTO, one codegen unit, `panic=abort`, and symbol stripping remain enabled. This is a speed-first build: build/link time and executable size may increase, so package size is reported by CI; no runtime speedup is claimed until benchmarked on the actual i3-6100U. It is not intended for pre-Skylake x86_64 CPUs.

## Build host vs. target device

Published packages are compiled on GitHub Actions, not on the target device. The target CPU/ISA, `x86_64-musl` ABI, and Wayland configuration define the resulting binary's compatibility and runtime behavior. The target's two physical CPU cores, 4 GB RAM, and HDD must not be used to cap CI compilation parallelism. Cargo and XBPS should use the build runner's available resources, with any limits justified by the runner's actual memory/CPU capacity or observed build failures.

## Wayland-only build

The package disables default features for upstream `gpui-pre-platform` 0.3.9 and enables only `font-kit`, `wayland`, and `runtime_shaders`. This is necessary because upstream's platform dependency enables both X11 and Wayland. Since this feature change alters the resolved dependency graph, the recipe refreshes only the exact `gpui-pre-platform@0.3.9` lockfile entry before the actual fetch/build steps use `--locked`; it does not run an unrestricted whole-project update. The package checks the normal/build Cargo feature graph for Wayland and rejects X11 features/crates, then checks the executable's direct ELF dependencies for X11 libraries.

Vulkan, Mesa, Wayland, xkbcommon, fontconfig and freetype dependencies are retained because GPUI still needs the renderer, display protocol, keyboard handling and font/text stack. The binary remains tuned for Skylake, while Cargo/XBPS compilation parallelism is determined by the GitHub Actions build runner rather than the target device.

## Latest release

Each successful package build from `main` publishes a GitHub Release whose tag and title are the upstream version only (for example, `0.7.8`). The release contains the native XBPS package as its only downloadable asset, using the version, package revision, and architecture in its filename: `velotype-0.7.8_1.x86_64-musl.xbps`.

Release notes document the source and packaging commits, target architecture, and CPU tuning. Checksum manifests and separate build-info files are not published as release assets. The package targets `x86_64-musl` and is optimized for Intel Skylake; it is not suitable for older x86_64 CPUs. When changing packaged output without an upstream version change, increment `revision` in `srcpkgs/velotype/template`. The workflow rejects changed bytes under the same version and revision and refuses revision downgrades.

Download the package from the [latest release](https://github.com/Azuuuuure222/velotype/releases/latest).

These are standalone package releases, not a signed, indexed XBPS repository.

## Build locally

Published release builds run on GitHub Actions. The following commands are for manual reproduction or debugging; when building manually, choose concurrency according to the machine doing the compilation, not the machine that will run the resulting package.

```sh
git clone https://github.com/Azuuuuure222/velotype.git
git clone https://github.com/void-linux/void-packages.git
cd velotype

./scripts/prepare-source.sh ../void-packages/hostdir/sources/velotype-0.7.8
mkdir -p ../void-packages/srcpkgs/velotype
cp -a srcpkgs/velotype/. ../void-packages/srcpkgs/velotype/

cd ../void-packages
./xbps-src -A x86_64-musl binary-bootstrap
./xbps-src -A x86_64-musl pkg velotype
```

The generated package is placed under `void-packages/hostdir/binpkgs/`.

## musl compatibility

The v0.7.8 lockfile no longer includes the previous `xattr 0.2.3` dependency, so the old `ENOATTR` → `ENODATA` workaround has been removed rather than carrying a stale Cargo registry patch. The build fetches locked dependencies, checks the resolved Cargo feature graph for Wayland and rejects X11 features/crates, then runs `cargo auditable build`. The install phase copies the already-built auditable release executable instead of compiling the dependency graph again via `cargo install`. The workflow's `scripts/test-wayland-patch.sh` tests the idempotent manifest patch, feature-graph rejection, build flags, error propagation, and binary-install behavior without compiling the application.

## CI and reproducibility

GitHub Actions builds the actual `.xbps` package through `xbps-src` and uploads it as a workflow artifact. CI caches the pinned source archive, Cargo registry and Void binary packages, plus cacheable Rust compiler results through `sccache`; the compiler cache is capped at 2 GiB and persisted between runs to reduce repeated compilation. The source cache key includes both the upstream commit and its expected SHA-256; source archives are validated against that checksum on every run, and the checksum is never silently regenerated. The workflow checks shell syntax, the Wayland-only feature patch, and the pinned source checksum before bootstrapping Void and compiling the application.

When updating Velotype, verify the upstream source commit and archive checksum, run the validation tests, and confirm the actual package build with `./xbps-src -A x86_64-musl pkg velotype` succeeds before publishing.
