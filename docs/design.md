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
- Scannable with grype so vulnerable dependencies can be tracked.
- Adding a new image should need no changes to the flake or CI.

## Image contract

The contract (user `1000:1000`, `/app`, the CA bundle and its distrusted
roots, tzdata, writable paths, scanning) is the table under
[Every image guarantees](../README.md#every-image-guarantees) in the README.
The one exception to its shell row: postgres ships a minimal static `/bin/sh`
because `initdb` bootstraps through libc `popen`/`system`.

The no-shell/no-package-manager row is enforced, not just intended: a
build-time closure check (`lib/default.nix`) fails any image whose contents
closure contains a store path named like a listed shell (bash, dash, busybox,
mksh, zsh, toybox, ksh, fish, tcsh, yash, nushell, …), coreutils, a runtime's
package-manager output (nodejs' `npm`, python's pip), or a `-dev` output, with
postgres's static `ash` as the sole declared exemption (`closureAllow`, matched
against the full store path so it admits that one derivation only). It is a
deny-list — exactly as strong as the list — not a proof of absence.

Because there is no shell, the entrypoint runs the application directly. That
means a self-contained artifact: a fat JAR, a static or dynamically-linked
binary, or interpreted code plus its already-installed dependencies.

Three kinds of image share this contract: **language runtimes** (jre, python,
node, php), **services** that package a nixpkgs binary plus its runtime closure
(nginx, redis, postgres, mysql, rabbitmq, memcached), and **compiled-binary
bases** that carry only the scaffolding and a libc layout (static, glibc, musl)
for a binary you drop at `/app/app`.

## libc axis

Every runtime/service image is built for both musl and glibc. The registry tag
encodes the libc: the **bare tag is musl** (the default) and **`-glibc`** opts in
(`varde-python:3.14` vs `varde-python:3.14-glibc`). musl is the default because a
smaller libc is less to patch and a smaller attack surface; glibc is there for
workloads that need it (manylinux-only wheels, glibc-built native code).

The axis is a single dimension in the module, not duplicated modules: a module's
runtime is a function of the libc's package set (`pkgs` for glibc,
`pkgs.pkgsMusl` for musl), and `vardeLib.mkVariants` crosses each version with
the available libcs, emitting `<tag>-musl` and `<tag>-glibc`. A version can opt
out of one libc (e.g. `varde-jre:17` is glibc-only — Adoptium ships no aarch64
Alpine/musl JRE for JDK 17; `varde-mysql` is glibc-only — its protobuf/abseil
pin is marked broken on musl in nixpkgs). The compiled-binary `static` base
carries no libc.

## Module framework

The build is data-driven so that images are described, not wired up by hand.

- `lib/default.nix` — shared scaffolding (the non-root `/etc`, CA certs, tzdata,
  the libc-aware FHS layout `mkLibcEnv`, a `relocate` helper), the `mkVariants`
  libc-cross helper, the `staticSpec`/`glibcSpec`/`muslSpec` base specs, and
  `buildImage` / `buildSbomApp`.
- `images/<name>.nix` — one module per image. A runtime/service module returns
  `{ description; latest?; variants = vardeLib.mkVariants pkgs { versions = …; }; }`
  where each version's `spec` is `libcPkgs: { contents ? [], entrypoint, cmd ? null,
  env ? [], fhs ? false, stopSignal ? null, sbomExtraComponents ? [ ],
  sbomStripCpes ? [ ], closureAllow ? [ ], strip ? true }` — `libc` is set by
  `mkVariants` (or the base specs), not by the module; `sbomExtraComponents`
  carries the runtime's NVD CPE identity (see below), `sbomStripCpes` rules
  (`{ foundBy ? …; name = <regex>; }`) that drop the CPEs of syft components
  whose CPE names a different NVD product (php's bundled extensions; the code
  stays covered by `php:php`), `stopSignal` a daemon's non-SIGTERM
  graceful-shutdown signal (postgres, nginx), `closureAllow` a closure-guard
  exemption, and `strip = false` opts a variant out of stripping ELF symbol
  tables (.symtab/.strtab) from its layers at image-assembly time
  (`stripImage` + `lib/strip-image.py`; store paths and their names are
  untouched, only file contents inside the layers shrink). `latest`
  must name a variant (the bare version for an `mkVariants` module); the flake
  rejects anything else at eval time. A compiled-binary base is
  `variants."latest" = vardeLib.staticSpec;` (or `glibcSpec`/`muslSpec`).
- `flake.nix` — `builtins.readDir ./images` discovers the modules and exposes
  `image-<name>-<tag>` packages, `sbom-<name>-<tag>` apps, the CI-driving
  `.#ciMatrix` (each entry carries its `libc`) / `.#latestTags`, and
  `.#imageAliases` (published names that mirror another image's digests, e.g.
  `go` → `static`, `rust` → `glibc`). Tag dots become underscores in attribute
  names, and the libc is part of the tag (`image-python-3_14-musl`).

The framework injects the non-root user, CA certs, tzdata, `/app`, a sticky
`/tmp`, common env, OCI labels, and the SBOM app into every image. A module only
supplies the contents and entrypoint, and opts into the FHS layout when its
applications load externally-compiled native code.

## FHS libc layout

`mkLibcEnv pkgs libc` symlinks the dynamic loader (glibc's `ld-linux-*.so` or
musl's `ld-musl-<arch>.so.1`, into both `/lib` and `/lib64`) plus that libc
and `libstdc++`/`libgcc_s` into `/lib`; the framework then sets
`LD_LIBRARY_PATH=/lib:/lib64` for FHS images. The targets are the same package
set used for the image's runtime, so there is no version mismatch. It is opted
into (`fhs = true`) by the Python and Node runtimes (manylinux/musllinux wheels,
native addons) and by the `glibc`/`musl` compiled-binary bases (a normal
`cargo`/`gcc` binary). The `static` base and the JRE/service images omit it — a
static binary needs no loader, and nixpkgs binaries find their libs via RPATH.

## SBOM and scanning

A distroless image has no OS package database, but every package in a Nix
image sits under `/nix/store/<hash>-<name>-<version>`. syft's Nix cataloger
reads those paths out of the image layers, so `grype <image>` — which runs
syft — inventories the shipped closure (glibc or musl, zlib, …, the runtime)
and matches it against NVD by CPE. Trivy cannot: it finds vulnerabilities only
through a distro package database or language lockfiles, has no Nix support
and no CPE matching, and reports 0 on these images whatever ships. grype is
the supported scanner; CI runs trivy for secrets only, so it never publishes
that false "clean".

The SBOM app runs that same syft over the built image tarball, so the SBOM CI
scans and attests matches what a user gets from scanning the pulled image.
Reading the tarball rather than the Nix store matters for CI time: the
previous generator (sbomnix) walked the store closure, so it had to realise
every package even when the image itself came from cache — with musl builds
evicted from Cachix that meant recompiling openssl, cmake, postgresql… in the
SBOM step. Where NVD files a component under a different vendor than the
cataloger's vendor=name guess (gnu:glibc, oracle:mysql,
python_software_foundation:cpython, f5:nginx *and* f5:nginx_open_source — NVD
splits open-source nginx CVEs across both products, …) — or where a pruned
runtime severed the store reference that would have named it at all (mysql,
rabbitmq/erlang) — the SBOM app appends a hand-authored component with the
exact NVD CPE, versioned from the same package binding that builds the image.
The SBOM is build metadata, attested to the image (not inside it), and scanned
with `grype sbom:…`; CI guards the scanner itself with a known-CVE canary
fixture that must produce findings, so a silently no-op scan fails the build
instead of reporting clean. CPE-based matching of Nix store contents is
best-effort — it compares upstream versions, so a CVE nixpkgs patched without
a version bump still shows, and expect some noise relative to a distro
package database.

Version-based CPE matching also reports CVEs nixpkgs has already patched, CVEs
filed against a different product, and CVEs in components that are not
shipped. Each image therefore carries an OpenVEX document
([`lib/vex.nix`](../lib/vex.nix)): a `fixed` statement for every CVE a nixpkgs
patch in the image is named after (derived from the derivation, so it tracks
the patch), plus reviewed statements with evidence in
[`vex/statements.nix`](../vex/statements.nix). A reviewed statement can be
limited to some images (`images = [ … ]`), because the same package purl can
be reachable in one image and dead code in another: CVE-2026-107778 (krb5
`krb5_rd_cred`, reached only through the GSS-API acceptor) is `not_affected`
in php and mysql and `affected` in postgres, which accepts GSSAPI once a
keytab is provided. An `affected` statement must carry an `action`, emitted as
OpenVEX `action_statement`, with the mitigation; it suppresses nothing, and
grype still reports the match. CI scans with `grype --vex`,
logs what was suppressed, and attests the document next to the SBOM; grype
keeps suppressed matches in `ignoredMatches`, so nothing is hidden. Every
syft component also gets exactly one NVD identity: an extra component
supersedes the syft components carrying the same (or a listed equivalent)
vendor:product, and a post-condition fails the SBOM if a duplicate survives.

The SBOM tooling (syft, jq, the script wrapper) comes from a separately pinned
nixpkgs — the `nixpkgs-tools` flake input, which the weekly bump never
touches — while the images and the component versions keep tracking the
moving `nixpkgs`. The split exists because the July 2026 weekly bumps landed a
nixpkgs where the SBOM tool of the day (sbomnix) no longer built (its
python3.14-df-diskcache dependency stopped compiling), and since every image
carries an SBOM app, that single tooling breakage failed every CI build job
for two weeks. A bump can now only break the image contents actually being
rebuilt, never the machinery that packages them.

## CI and tagging

The build matrix is derived from `.#ciMatrix` (image × tag × libc) crossed with
`{amd64, arm64}` and runs on native runners. Each image is built, its SBOM
generated and scanned, then smoke-tested before publishing (build.yml's
*Smoke test* step):

- jre `java -version`; python, node and php print from a one-liner
  (`python3 -c`, `node -e`, `php -r`);
- static, glibc and musl run a hello compiled with the runner's toolchain
  through `/app/app` (`cc -static`, `cc`, `musl-gcc`), exercising each libc's
  loader;
- redis: `redis-cli ping` answers `PONG` (via `docker exec`);
- postgres: `initdb` on a volume, then `pg_isready` and `psql -c 'SELECT 1'`;
- mysql: `--initialize-insecure` on a volume, then `mysqladmin ping` and
  `mysql -e 'SELECT 1'`;
- rabbitmq: `rabbitmq-diagnostics ping`; the musl amd64 build also boots a
  BEAM under an `LD_PRELOAD` shim that simulates AMX-sized signal frames
  ([`.github/smoke/sigaltstack-amx.c`](../.github/smoke/sigaltstack-amx.c));
- memcached: `stats` over TCP from the runner (the image has no client);
- nginx: an HTTP GET on `:8080` returns a mounted `index.html`.

Each per-arch
image is then pushed by digest (untagged), keyless-signed with cosign
(Sigstore, GitHub OIDC — no long-lived keys), given CycloneDX SBOM (its own
arch's closure SBOM, attached to the image), OpenVEX and vulnerability-scan
(cosign `vuln`, CI's grype result) attestations plus a SLSA build-provenance
attestation, verified — and only then is the per-arch tag
moved onto that digest, so a tag never points at an unsigned image. The
multi-arch indexes are stitched from those verified digests per image:tag pair
(a failed leg holds back only its own lists, and the run goes red naming them)
and signed too. Publishing is main-only — the signing identity is always
`build.yml@refs/heads/main`. These land in the public Rekor log; verification
commands are in the README.

Registry tags: `:<tag>-<libc>` (a multi-arch manifest list) and
`:<tag>-<libc>-<arch>` per-arch; a bare `:<tag>` and `:latest` aliasing the
default libc (musl if built, else glibc); `:latest-glibc`; and the `varde-go` /
`varde-rust` alias images mirroring `varde-static` / `varde-glibc`. Each list
is first pushed under a fixed `<tag>-staging` name (signed and verified there,
then the real tag is moved onto that digest — see build.yml); those `-staging`
tags are a CI implementation detail, overwritten every run, and are not a
supported way to consume an image.

The weekly `bump-lock.yml` validates a nixpkgs bump before it lands: it
commits the new `flake.lock` to the `bump/flake-lock` side branch (a
GitHub-signed commit on top of main's head), runs `build.yml` with
`verify_only` (full matrix, no sign/push/tag) and `e2e.yml` on that commit,
and only if both are green fast-forwards `main` to that exact commit and
dispatches the publishing run. A nixpkgs that breaks a build leaves `main` and
the published images on last week's lock. CVE fixes flow through, and every
published image corresponds to a commit whose lock reproduces it.

A separate `e2e.yml` workflow builds every example in `examples/<image>/<variant>/`
on top of a locally-built base, smoke-tests that the app runs, and asserts a
per-image size budget (`scripts/e2e.sh`): on PRs, on `main` after every
successful *push* `build-image` run, and from `bump-lock.yml` (its
`verify-e2e` job) on the bumped lock before it lands. The weekly publish does
not chain into it: bump-lock dispatches `build.yml` with `GITHUB_TOKEN`, and
GitHub raises no `workflow_run` event for a run started that way, so
`verify-e2e` is the weekly lock's e2e coverage.

`rebuild-watchdog.yml` runs every 3 hours: it re-runs the failed jobs of the
newest bump-lock and publishing build-image runs on `main` (3 attempts in
total, cancelled runs left alone), checks that each `.#latestTags` image's
linux/amd64 digest carries a verified vuln attestation from the last 10 days,
and keeps one `rebuild-failed` issue open while either is wrong.

In every workflow, musl service/runtime variants that are not in the public
Nix cache come from the shared `varde` Cachix cache that `build.yml` populates
(compiled from source only on a cache-cold first run); Actions minutes are
free on public repos.

## Maintaining a fork

These steps are done for `ghcr.io/mathiasror`; they apply if you fork and
publish your own.

> **Cache setup, one-time:** create a free open-source cache named `varde` at
> [cachix.org](https://cachix.org) (keep it **public** so fork PRs and end users
> can read it), then add its write token as the repo secret `CACHIX_AUTH_TOKEN`
> (Settings → Secrets and variables → Actions). Reads are anonymous on a public
> cache — the token is only needed to *push*; without it builds still work and
> still pull the cache, they just can't refill it.

> **First publish, one-time step:** packages pushed by Actions are created
> **private** by default — even from a public repo — so anonymous `docker pull`
> would return 401 until you flip them. After the first successful build, set
> each `varde-*` package to **Public** once (GHCR → the package → *Package
> settings* → *Change visibility*) and connect it to this repository. Only then
> does the "just `docker pull`, no token" promise hold.

> **Publish checklist:** after a run on `main`,
> - a red run's **manifest** job lists the tags whose manifest lists were *not*
>   refreshed (a build leg failed or timed out); per-arch tags of the legs that
>   succeeded are always current and signed. Re-run the failed legs, or fix and
>   dispatch again from `main`; re-running only works within 7 days of the
>   original run (the per-leg digest artifacts the manifest job stitches from
>   expire then) — after that, dispatch a fresh build from `main`;
> - confirm an anonymous `docker pull ghcr.io/mathiasror/varde-jre:latest` (any
>   bare tag) resolves;
> - first publish only: flip each `varde-*` package to **Public** (previous note).

## Non-goals

- The bases stay minimal: native dependencies needing extra system libraries
  (for example `libpq`) are added by the application image, not the base.
- Compiled binaries pick the base that matches their linkage: `varde-static`
  (static — Go `CGO_ENABLED=0`, musl-static Rust), `varde-glibc` (default
  `cargo build`, cgo Go), or `varde-musl` (musl-dynamic). `varde-go` and
  `varde-rust` are convenience aliases of `varde-static` and `varde-glibc`.
- No shell means no start scripts (npm `start`, Gradle `application`); use a
  direct entry file or artifact, or override the command.
