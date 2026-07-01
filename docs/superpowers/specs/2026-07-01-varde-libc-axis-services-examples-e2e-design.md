# varde expansion — libc axis, compiled-binary bases, service images, examples, e2e

Date: 2026-07-01
Status: approved (design)

## Overview

Expand varde along five fronts while keeping the data-driven, "describe an image,
don't wire it up" model:

1. **libc axis** — every runtime/service image can be built against **musl
   (default)** or **glibc (opt-in)**. musl is the default because it has a
   smaller codebase and CVE history, which matches varde's minimal-attack-surface
   thesis. glibc is the escape hatch for when musl isn't feasible.
2. **Compiled-binary bases** — replace the language-named `varde-go`/`varde-rust`
   with three honest, general bases: `varde-static` (no libc), `varde-musl`
   (dynamic musl), `varde-glibc` (dynamic glibc). Keep `varde-go`/`varde-rust`
   as published **alias digests** for discoverability.
3. **Service images** — add `varde-nginx` and `varde-redis`, following the same
   conventions (non-root, no shell, relocated nixpkgs binary + RPATH'd closure),
   each on the libc axis.
4. **Examples** — restructure to `examples/<image>/<variant>/`, several per image,
   each a self-contained buildable project.
5. **e2e** — a CI harness that builds every example against locally-built bases,
   smoke-tests it, and asserts image-size budgets.

Plus the docs/site sync that (1)–(3) force.

## Verified findings (basis for the design)

Checked against the pinned-ish nixpkgs (`nix eval` + `cache.nixos.org` narinfo):

- **musl JRE is feasible and cheap.** `pkgsMusl.temurin-jre-bin-21.src.url` →
  `OpenJDK21U-jre_x64_alpine-linux_hotspot_21.0.11_10.tar.gz`. It's Temurin's
  **Alpine/musl prebuilt** binary (a light unpack+patchelf), *not* a from-source
  OpenJDK build.
- **Gap:** `pkgsMusl.temurin-jre-bin-17` **fails to evaluate on aarch64-linux**
  (no Adoptium aarch64 alpine build for JDK 17). So `varde-jre:17` is **glibc-only**;
  `varde-jre:21` and `:25` get musl (25's aarch64 alpine build to be verified in
  implementation — fall back to glibc-only for a given version if a musl build is
  missing on any published arch).
- **musl build cost is a non-issue for a public repo.** `pkgsMusl.python313` is
  cached on x86_64; `node`/`redis`/`nginx` musl and *all* aarch64-musl build from
  source. GitHub Actions minutes are free on public repos and each image is its
  own parallel job, so this is wall-clock (node musl is the long pole), not money.
  A Cachix/FlakeHub cache is an optional later speedup, not a prerequisite.

## Naming & tag scheme

**Bare tag = musl (default). `-glibc` suffix = opt-in.** To keep tag semantics
unambiguous and CI uniform, every variant also publishes an **explicit
libc-qualified** tag, and the bare tag is an alias to the default libc.

Per runtime/service image `<img>` with version `<v>` (services use `latest`):

| Tag | Meaning |
| --- | --- |
| `<v>` | alias → the default-libc image (musl if available, else glibc) |
| `<v>-musl` | musl build (when available) |
| `<v>-glibc` | glibc build (always) |
| `<v>-musl-amd64` / `<v>-musl-arm64` | per-arch musl |
| `<v>-glibc-amd64` / `<v>-glibc-arm64` | per-arch glibc |
| `latest` | per-image default-LTS, default libc (e.g. `varde-jre:latest` = `21` musl) |
| `latest-glibc` | per-image default-LTS, glibc |

Per-arch tags are always libc-qualified (no bare `<v>-amd64`); bare aliases exist
only for the multi-arch `<v>`, `latest`, and `latest-glibc`.

**Compiled-binary bases** keep their own image names (the libc *is* the identity):

| Image | Base | libc |
| --- | --- | --- |
| `varde-static` | scratch-like | none (static binaries) |
| `varde-musl` | dynamic | musl loader + libc at FHS paths |
| `varde-glibc` | dynamic | glibc loader + libc at FHS paths |
| `varde-go` (alias) | mirror of `varde-static` | — |
| `varde-rust` (alias) | mirror of `varde-glibc` | — |

`varde-rust`→glibc because a default `cargo build` targets `…-linux-gnu`. A
statically-linked musl Rust binary uses `varde-static`; a dynamically-linked musl
binary uses `varde-musl`. Documented in the rust example.

## Component 1 — libc axis (framework changes)

`lib/default.nix`:

- **Spec gains `libc`**: `spec = { contents ? [], entrypoint, cmd ? null, env ? [],
  libc ? "glibc", fhs ? false }`, `libc ∈ {"musl","glibc",null}`. `null` = static
  (the `varde-static` base only).
- **`fhs` becomes libc-aware.** Generalize `mkFhsEnv` into a libc-parameterized
  `mkLibcEnv pkgs libc` that lays down:
  - glibc: `ld-linux-*.so` loader (in `/lib` and `/lib64`) + glibc + libstdc++/libgcc_s in `/lib`.
  - musl: `ld-musl-<arch>.so.1` loader + musl `libc.so` + libstdc++/libgcc_s (from the musl toolchain) in `/lib`.
  Keep the same "symlink into the same closure glibc/musl, no version mismatch" guarantee.
- **`LD_LIBRARY_PATH`** is set by `buildImage` for any `fhs` image (glibc or musl), value `/lib:/lib64`.
- **`commonEnv`, non-root `/etc`, certs, tzdata, `/app`, sticky `/tmp`, labels, SBOM app** are unchanged and libc-agnostic.

Flake (`flake.nix`):

- Modules produce variants keyed by **libc-qualified tag** (`3.13-musl`, `3.13-glibc`).
  A `vardeLib` helper `mkRuntimeVariants` crosses a `version → (libcPkgs → runtime derivation)`
  map with the available libcs, emitting one spec per (version, libc) with `libc` set
  and the runtime built from `pkgs` (glibc) or `pkgs.pkgsMusl` (musl). A version may
  omit musl when unavailable (jre-17).
- `ciMatrix` entries gain `libc` and the libc-qualified `attr`/`tag`/`sbomName`
  (`image-python-3_13-musl`). String fields stay system-independent.
- `latestTags` stays per-image → the **default-libc default-LTS** tag; add derivation
  of `latest`/`latest-glibc` for the manifest step.
- **Bare-tag + `:latest`/`:latest-glibc` aliases** and the **go/rust image aliases**
  are expressed as a new flake output (`aliases`) consumed by CI's manifest job —
  they are extra *names/manifests* over already-built per-arch digests, never extra builds.
- **Per-arch availability gaps** (jre-17 aarch64-musl): a module simply does not
  emit that (version, libc) variant, so it never enters the matrix. Where a musl
  build is missing on *some but not all* arches, the version is treated as
  glibc-only to avoid an asymmetric manifest.

## Component 2 — compiled-binary bases

- New modules `images/static.nix`, `images/musl.nix`, `images/glibc.nix`. Each is a
  single-variant `latest` image with `entrypoint = ["/app/app"]` and:
  - static: `libc = null`, no `fhs`, empty contents (scratch-like).
  - musl: `libc = "musl"`, `fhs = true`.
  - glibc: `libc = "glibc"`, `fhs = true`.
  Shared specs `staticSpec`/`glibcSpec`/`muslSpec` live in `vardeLib` to avoid duplication.
- Delete `images/go.nix`, `images/rust.nix`.
- Flake `aliases` output: `{ go = "static"; rust = "glibc"; }`. CI manifest job
  publishes `varde-go`/`varde-rust` tags (`latest`, per-arch, `latest`) pointing at
  the canonical per-arch digests via `docker buildx imagetools create` — true mirrors.

## Component 3 — service images

Pattern: `relocate` the nixpkgs package under `/runtime`; **no `fhs`** (the nixpkgs
binary finds its libs via RPATH, like the JRE). Both are on the libc axis
(`redis`/`nginx` from `pkgs` for glibc and `pkgs.pkgsMusl` for musl).

**`images/redis.nix`** — single `latest` version (nixpkgs ships one redis):
- entrypoint `/runtime/bin/redis-server`; runs fine as `1000:1000`.
- Default CMD: none (redis binds `0.0.0.0:6379`, unprivileged; writes to `WORKDIR /app`).
- Example shows mounting/`COPY`ing a `redis.conf` and overriding CMD.

**`images/nginx.nix`** — single `latest` version:
- Ship a **non-root default config** at `/etc/nginx/nginx.conf` + `mime.types`:
  `pid /tmp/nginx.pid`, `error_log /dev/stderr`, `access_log /dev/stdout`,
  `listen 8080`, `root /app`, and `*_temp_path` under `/tmp` (writable sticky).
- entrypoint `["/runtime/bin/nginx","-g","daemon off;","-c","/etc/nginx/nginx.conf"]`.
- Non-root binds 8080 (unprivileged). Example: `COPY site/ /app/`, expose 8080.

## Component 4 — examples restructure

Move to `examples/<image>/<variant>/`, each a self-contained project with app
source + `Dockerfile`. **Every Dockerfile takes `ARG BASE_IMAGE=<pinned public tag>`**
and `FROM ${BASE_IMAGE}`, so the e2e harness can inject a locally-built base while
the default stays a real pinned tag. Preserve the current examples' inline teaching
comments.

- `examples/jre/spring-boot-gradle/` — minimal Spring Boot app (latest stable
  Spring Boot targeting JDK 21), Gradle `bootJar`, `COPY build/libs/*-all.jar` /
  the boot jar → `/app/app.jar`. Verify the current Spring Boot version at build time.
- `examples/python/simple/` — one `main.py`, no deps.
- `examples/python/requirements-venv/` — `requirements.txt`, deps installed with
  `pip --target` (or a venv) in a builder, `PYTHONPATH`/site-packages copied in.
- `examples/python/uv/` — `pyproject.toml` + `uv.lock`, deps resolved with `uv`
  (`uv sync`/`uv export`), the resolved env copied in.
- `examples/node/simple/` — one `main.js`.
- `examples/node/express/` — production Express app, `npm ci --omit=dev`.
- `examples/go/simple/` — `main.go`, static build, `FROM varde-static` (note the
  `varde-go` alias).
- `examples/rust/simple/` — `Cargo.toml` + `src/main.rs`, default gnu build,
  `FROM varde-glibc` (note the `varde-rust` alias and the musl→static/musl options).
- `examples/nginx/static-site/` — minimal static site served on :8080.
- `examples/redis/simple/` — run redis with a small custom `redis.conf`.

Examples lead with musl (the default tag). README's example links updated.

## Component 5 — e2e harness

`scripts/e2e.sh` + `.github/workflows/e2e.yml` (Linux runners; also runnable on any
Linux+Docker host). Triggered on PRs/pushes touching `examples/**`, `images/**`,
`lib/**`, `flake.nix`.

Per run:
1. `nix build` each base image needed by the examples, `docker load`, tag `varde-<img>:e2e`.
2. For each `examples/<img>/<variant>/`, `docker build --build-arg BASE_IMAGE=varde-<img>:e2e`.
3. **Smoke test** appropriate to the example: HTTP 200 for servers (jre/node/nginx),
   expected stdout for CLIs (go/rust/python), `redis-cli PING` → `PONG` for redis.
   This proves the artifact landed at the right path and runs.
4. **Size check**: `docker image inspect --format '{{.Size}}'`; compare to a per-image
   **budget**; **fail** if exceeded; print a size table to the job summary.

Budgets start generous (catch a shell/pkg-manager sneaking in, not micro-regressions)
and can tighten later. Initial budgets (tunable): go ~20MB, rust ~30MB, static/glibc/musl
bases small; python ~150MB, node ~180MB, jre ~260MB, nginx ~60MB, redis ~50MB
(musl variants generally smaller — budget the larger glibc case).

## Component 6 — docs & site sync

- `README.md` image table: static/musl/glibc(+go/rust aliases), jre/python/node
  (musl default, `-glibc` opt-in), nginx/redis; a short "Examples" section linking
  the new dirs; note musl-default rationale and the jre-17 glibc-only exception.
- `docs/design.md`: libc axis, `mkLibcEnv`, service-image pattern, alias mechanism.
- `site/`: catalog updated to the new images; "musl by default, glibc on request"
  as a security talking point; keep copy honest (compiled-binary + service bases,
  not "5 languages"). OG image copy already generic — no change needed.

## Testing strategy

- **Eval**: `nix eval .#ciMatrix` / `.#latestTags` / `.#aliases` stay well-formed;
  `nix flake show` clean; the missing jre-17-aarch64-musl combo is absent from the matrix.
- **Build (CI, Linux)**: every matrix entry builds; smoke tests in `build.yml` extended
  to cover nginx (curl :8080) and redis (PING) and to run for both libcs.
- **e2e (CI, Linux)**: Component 5 — the user-facing examples actually build on the bases and run.
- **Local (Darwin)**: eval-only checks + `actionlint`; no image builds.

## Phasing (for the implementation plan)

- **A. Framework** — `lib` libc-aware `mkLibcEnv`, spec `libc`, `mkRuntimeVariants`; flake `libc`/`aliases`/tag-alias outputs. Convert jre/python/node to musl-default + glibc opt-in.
- **B. Compiled-binary bases** — static/musl/glibc modules + go/rust aliases; delete go.nix/rust.nix. (after A)
- **C. Service images** — nginx/redis modules + smoke tests. (after A; parallel with B)
- **D. Examples** — restructure + new example projects. (after B/C exist)
- **E. e2e** — `scripts/e2e.sh` + `e2e.yml`. (after D)
- **F. Docs/site** — README/design/site sync. (last)

CI (`build.yml`) manifest job extended for libc-qualified tags, bare/`latest`/`latest-glibc`
aliases, and go/rust image aliases — part of A/B.

## Open verification items (resolve during implementation)

- Confirm `pkgsMusl.temurin-jre-bin-25` builds on **both** arches (alpine aarch64 for 25).
  If not, make 25 glibc-only like 17.
- Confirm `pkgsMusl.nodejs-slim_{22,24}`, `pkgsMusl.redis`, `pkgsMusl.nginx` **build**
  (they evaluate; buildability is verified in CI). If a specific musl build is broken
  upstream, that image/version falls back to glibc-only with a documented note.
- Confirm the musl loader path/name per arch (`ld-musl-x86_64.so.1`, `ld-musl-aarch64.so.1`)
  and that `mkLibcEnv` musl branch produces a working dynamic base (e2e rust/C dynamic-musl probe).
- Pin the exact latest stable Spring Boot at implementation time.

## Non-goals

- No Cachix/binary-cache setup now (optional future speedup).
- No musl for `varde-static` (static binaries embed their libc).
- No from-source OpenJDK: musl JRE only where an Adoptium alpine prebuilt exists.
