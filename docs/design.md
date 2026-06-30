# Design notes

varde is a set of minimal, distroless container base images built with Nix.
Each image carries only the runtime an application needs and nothing else: no
shell, no package manager, no coreutils. Every image runs as a non-root user and
is published multi-arch (amd64 + arm64) to GHCR.

## Goals

- Only runtime dependencies in the image; no shell, package manager, or utilities.
- Non-root by default.
- amd64 or arm64 selectable by tag.
- Easy to use: copy a self-contained artifact in, done.
- Scannable by Trivy so vulnerable dependencies can be tracked.
- Adding a new image should need no changes to the flake or CI.

## Image contract

| Property | Value |
| --- | --- |
| User | `1000:1000` (`app`, non-root) |
| Working directory | `/app` (owned by `1000:1000`) |
| Shell / package manager | none |
| TLS | CA bundle at `/etc/ssl/certs/ca-certificates.crt` |
| Timezones | tzdata at `/usr/share/zoneinfo` |
| Writable paths | `/app`, `/tmp` (sticky) |

Because there is no shell, the entrypoint runs the application directly. That
means a self-contained artifact: a fat JAR, a static or dynamically-linked
binary, or interpreted code plus its already-installed dependencies.

## Module framework

The build is data-driven so that images are described, not wired up by hand.

- `lib/default.nix` — shared scaffolding (the non-root `/etc`, CA certs, tzdata,
  an optional FHS glibc/libstdc++ layout, a `relocate` helper) plus `buildImage`
  and `buildSbomApp`.
- `images/<name>.nix` — one module per image, returning
  `{ description; latest?; variants = { "<tag>" = spec; }; }`, where
  `spec = { contents ? [], entrypoint, cmd ? null, env ? [], fhs ? false }`.
- `flake.nix` — `builtins.readDir ./images` discovers the modules and exposes
  `image-<name>-<tag>` packages, `sbom-<name>-<tag>` apps, and the CI-driving
  `.#ciMatrix` / `.#latestTags`. Tag dots become underscores in attribute names.

The framework injects the non-root user, CA certs, tzdata, `/app`, a sticky
`/tmp`, common env, OCI labels, and the SBOM app into every image. A module only
supplies the language-specific contents and entrypoint, and opts into the FHS
layout when its applications load externally-compiled native code.

## FHS glibc layout

`mkFhsEnv` symlinks the dynamic loader to `/lib64/ld-linux-*.so` and
glibc/libstdc++/libgcc_s into `/lib`, and sets `LD_LIBRARY_PATH`. The targets are
the same nixpkgs glibc used in the closure, so there is no version mismatch. It
is used by the Python, Node, and Rust images (manylinux wheels, native addons,
the default gnu Rust target). The Go image is static and omits it.

## SBOM and scanning

A distroless image has no OS package database, so `trivy image` alone finds no
system packages. Nix knows the exact closure, so `sbomnix` emits a CycloneDX SBOM
(with CPEs) covering the system packages and the runtime. The SBOM is generated
as build metadata, kept out of the image, and scanned with `trivy sbom`. An
application's own dependencies are covered natively by `trivy image` once its
image is built.

## CI and tagging

The build matrix is derived from `.#ciMatrix` crossed with `{amd64, arm64}` and
runs on native runners. Each image is built, its SBOM generated and scanned, then
smoke-tested before publishing: interpreter images run a one-liner; the Go and
Rust images run a binary compiled with the runner's system toolchain through the
`/app/app` entrypoint, which exercises the scratch base and the FHS loader. Tags
are `:<tag>` (a multi-arch manifest list), `:<tag>-amd64`, `:<tag>-arm64`, and a
per-image `:latest`. A weekly rebuild against the latest nixpkgs picks up CVE
fixes.

## Non-goals

- The bases stay minimal: native dependencies needing extra system libraries
  (for example `libpq`) are added by the application image, not the base.
- Go binaries are expected to be static (`CGO_ENABLED=0`); cgo/dynamic Go can use
  the Rust (glibc) base, and fully-static musl Rust can use the Go base.
- No shell means no start scripts (npm `start`, Gradle `application`); use a
  direct entry file or artifact, or override the command.
