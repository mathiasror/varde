# Design notes

varde is a set of minimal, distroless container base images built with Nix.
Each image carries only the runtime an application needs and nothing else: no
shell, no package manager, no coreutils. Every image runs as a non-root user and
is published multi-arch (amd64 + arm64) to GHCR. Where there is a choice of C
library, images default to musl (smaller, fewer CVEs) with glibc opt-in.

## Goals

- Only runtime dependencies in the image; no shell, package manager, or utilities.
- Non-root by default.
- amd64 or arm64 selectable by tag.
- musl by default, glibc opt-in — a smaller libc where the workload allows it.
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

Three kinds of image share this contract: **language runtimes** (jre, python,
node), **services** that package a nixpkgs binary plus its runtime closure
(nginx, redis), and **compiled-binary bases** that carry only the scaffolding and
a libc layout (static, glibc, musl) for a binary you drop at `/app/app`.

## libc axis

Every runtime/service image is built for both musl and glibc. The registry tag
encodes the libc: the **bare tag is musl** (the default) and **`-glibc`** opts in
(`varde-python:3.13` vs `varde-python:3.13-glibc`). musl is the default because a
smaller libc is less to patch and a smaller attack surface; glibc is there for
workloads that need it (manylinux-only wheels, glibc-built native code).

The axis is a single dimension in the module, not duplicated modules: a module's
runtime is a function of the libc's package set (`pkgs` for glibc,
`pkgs.pkgsMusl` for musl), and `vardeLib.mkVariants` crosses each version with
the available libcs, emitting `<tag>-musl` and `<tag>-glibc`. A version can opt
out of one libc (e.g. `varde-jre:17` is glibc-only — Adoptium ships no aarch64
Alpine/musl JRE for JDK 17). The compiled-binary `static` base carries no libc.

## Module framework

The build is data-driven so that images are described, not wired up by hand.

- `lib/default.nix` — shared scaffolding (the non-root `/etc`, CA certs, tzdata,
  the libc-aware FHS layout `mkLibcEnv`, a `relocate` helper), the `mkVariants`
  libc-cross helper, the `staticSpec`/`glibcSpec`/`muslSpec` base specs, and
  `buildImage` / `buildSbomApp`.
- `images/<name>.nix` — one module per image. A runtime/service module returns
  `{ description; latest?; variants = vardeLib.mkVariants pkgs { versions = …; }; }`
  where each version's `spec` is `libcPkgs: { contents ? [], entrypoint, cmd ? null,
  env ? [], libc, fhs ? false }`. A compiled-binary base is
  `variants."latest" = vardeLib.staticSpec;` (or `glibcSpec`/`muslSpec`).
- `flake.nix` — `builtins.readDir ./images` discovers the modules and exposes
  `image-<name>-<tag>` packages, `sbom-<name>-<tag>` apps, the CI-driving
  `.#ciMatrix` (each entry carries its `libc`) / `.#latestTags`, and
  `.#imageAliases` (published names that mirror another image's digests, e.g.
  `go` → `static`, `rust` → `glibc`). Tag dots become underscores in attribute
  names, and the libc is part of the tag (`image-python-3_13-musl`).

The framework injects the non-root user, CA certs, tzdata, `/app`, a sticky
`/tmp`, common env, OCI labels, and the SBOM app into every image. A module only
supplies the contents and entrypoint, and opts into the FHS layout when its
applications load externally-compiled native code.

## FHS libc layout

`mkLibcEnv pkgs libc` symlinks the dynamic loader (glibc's `ld-linux-*.so` in
`/lib` and `/lib64`, or musl's `ld-musl-<arch>.so.1` in `/lib`) plus that libc
and `libstdc++`/`libgcc_s` into `/lib`; the framework then sets
`LD_LIBRARY_PATH=/lib:/lib64` for FHS images. The targets are the same package
set used for the image's runtime, so there is no version mismatch. It is opted
into (`fhs = true`) by the Python and Node runtimes (manylinux/musllinux wheels,
native addons) and by the `glibc`/`musl` compiled-binary bases (a normal
`cargo`/`gcc` binary). The `static` base and the JRE/service images omit it — a
static binary needs no loader, and nixpkgs binaries find their libs via RPATH.

## SBOM and scanning

A distroless image has no OS package database, so `trivy image` alone finds no
system packages. Nix knows the exact closure, so `sbomnix` emits a CycloneDX SBOM
(with CPEs) covering the system packages (glibc or musl, zlib, …) and the
runtime. The SBOM is generated as build metadata, kept out of the image, and
scanned with `trivy sbom`. An application's own dependencies are covered natively
by `trivy image` once its image is built.

## CI and tagging

The build matrix is derived from `.#ciMatrix` (image × tag × libc) crossed with
`{amd64, arm64}` and runs on native runners. Each image is built, its SBOM
generated and scanned, then smoke-tested before publishing: interpreter images
run a one-liner; the compiled-binary bases run a binary compiled with the
runner's toolchain through `/app/app` (static via `cc -static`, glibc via `cc`,
musl via `musl-gcc`), exercising each libc's loader; the service images are
probed over the network (nginx on `:8080`, `redis-cli ping`). After publishing,
each per-arch image is keyless-signed with cosign (Sigstore, GitHub OIDC — no
long-lived keys) and gets a CycloneDX SBOM attestation (its own arch's closure
SBOM, attached to the image) plus a SLSA build-provenance attestation; the
multi-arch indexes are signed too. These land in the public Rekor log;
verification commands are in the README.

Registry tags: `:<tag>-<libc>` (a multi-arch manifest list) and
`:<tag>-<libc>-<arch>` per-arch; a bare `:<tag>` and `:latest` aliasing the
default libc (musl if built, else glibc); `:latest-glibc`; and the `varde-go` /
`varde-rust` alias images mirroring `varde-static` / `varde-glibc`. A weekly
rebuild against the latest nixpkgs picks up CVE fixes.

A separate `e2e.yml` workflow builds every example in `examples/<image>/<variant>/`
on top of a locally-built base, smoke-tests that the app runs, and asserts a
per-image size budget (`scripts/e2e.sh`). musl service/runtime variants that are
not in the public Nix cache build from source there; Actions minutes are free on
public repos.

## Non-goals

- The bases stay minimal: native dependencies needing extra system libraries
  (for example `libpq`) are added by the application image, not the base.
- Compiled binaries pick the base that matches their linkage: `varde-static`
  (static — Go `CGO_ENABLED=0`, musl-static Rust), `varde-glibc` (default
  `cargo build`, cgo Go), or `varde-musl` (musl-dynamic). `varde-go` and
  `varde-rust` are convenience aliases of `varde-static` and `varde-glibc`.
- No shell means no start scripts (npm `start`, Gradle `application`); use a
  direct entry file or artifact, or override the command.
