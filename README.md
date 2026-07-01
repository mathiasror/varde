# varde

Minimal, **distroless** container base images built with Nix. Each image carries
only what an app needs to run — the language runtime (or, for compiled
languages, just the libs a binary links against) and nothing else: **no shell,
no package manager, no coreutils, no busybox** — and every image runs as an
unprivileged user. Where there's a choice of C library, images default to
**musl** (a smaller codebase and CVE history), with **glibc** one tag away.

> A *varde* (Norwegian for a *cairn*) is a small stack of stones that marks a
> trail. These are the smallest stacks you need to run an app, and nothing more.

## Images

**Language runtimes**

| Image | Tags | Runs | Drop-in contract |
| --- | --- | --- | --- |
| `varde-jre` | `17`* `21` `25` `latest`(=21) | JVM apps (Java/Kotlin) | `COPY app.jar /app/app.jar` (fat/boot jar) |
| `varde-python` | `3.11` `3.12` `3.13` `latest`(=3.13) | Python apps | `COPY` interpreter deps + code into `/app` |
| `varde-node` | `22` `24` `latest`(=24) | Node.js apps | `COPY node_modules` + code into `/app` |

**Services**

| Image | Tags | Runs | Drop-in contract |
| --- | --- | --- | --- |
| `varde-nginx` | `latest` | static sites (non-root, listens on `:8080`) | `COPY site/ /app/` |
| `varde-redis` | `latest` | Redis server | run as-is, or pass a `redis.conf` via `CMD` |

**Compiled-binary bases** (bring your own binary at `/app/app`)

| Image | Tags | Runs |
| --- | --- | --- |
| `varde-static` | `latest` | any **static** binary — Go `CGO_ENABLED=0`, musl-static Rust, static C/Zig |
| `varde-glibc` | `latest` | any **glibc-dynamic** binary — a default `cargo build`, cgo Go, C/C++ |
| `varde-musl` | `latest` | any **musl-dynamic** binary |

`varde-go` and `varde-rust` are published as **aliases** for discoverability:
`varde-go` → `varde-static`, `varde-rust` → `varde-glibc` (the same digests).

Each is published to **GHCR** under `ghcr.io/mathiasror/<image>`, multi-arch
(`amd64` + `arm64`).

### libc: musl by default, glibc on request

Every runtime/service image is built for both C libraries. **The bare tag is
musl** (the default); append **`-glibc`** to opt in to glibc:

```dockerfile
FROM ghcr.io/mathiasror/varde-python:3.13          # musl (default)
FROM ghcr.io/mathiasror/varde-python:3.13-glibc    # glibc (opt-in)
```

musl is the default because a smaller libc means less to patch and a smaller
attack surface. Reach for `-glibc` when something needs it — a wheel with only
manylinux (glibc) binaries, a native addon built against glibc, or a prebuilt
dependency that assumes glibc. Per-arch tags are libc-qualified, e.g.
`:21-musl-arm64` or `:3.13-glibc-amd64`.

*`varde-jre:17` is **glibc-only** — Adoptium ships no aarch64 Alpine/musl JRE for
JDK 17; `:21` and `:25` default to musl. `varde-static` carries no libc (static
binaries embed their own), so it has no `-musl`/`-glibc` split.

### Every image guarantees

| Property | Value |
| --- | --- |
| User | `1000:1000` (`app`, non-root) |
| Working directory | `/app` (owned by `1000:1000`) |
| Shell / package manager | **none** |
| TLS | CA bundle at `/etc/ssl/certs/ca-certificates.crt` (`SSL_CERT_FILE` set) |
| Timezones | tzdata at `/usr/share/zoneinfo` (`TZDIR` set) |
| Writable paths | `/app`, `/tmp` (sticky) |
| Scanning | per-image CycloneDX SBOM for Trivy (see below) |

Images that load **externally-compiled** native code (`python`, `node`, and the
`glibc`/`musl` bases) also ship that libc's loader + `libstdc++`/`libgcc_s` at
standard FHS paths (`/lib`, `/lib64`) so manylinux/musllinux wheels, native node
addons, and a normal `cargo`/`gcc` binary find their loader and libraries.
`varde-static` is scratch-like (static binaries need none of this).

## Using the images

The integration is "drop your app in." Because there is no shell, the entrypoint
runs your app directly — bring a self-contained artifact (a fat JAR, a binary, or
code plus its already-installed dependencies). Full, buildable examples live
under [`examples/`](examples/) — each takes an `ARG BASE_IMAGE`, so you can
`docker build` it against any tag:

- **JVM** — [`examples/jre/spring-boot-gradle/`](examples/jre/spring-boot-gradle/) (Spring Boot, Gradle `bootJar`)
- **Python** — [`simple`](examples/python/simple/), [`requirements-venv`](examples/python/requirements-venv/), [`uv`](examples/python/uv/)
- **Node** — [`simple`](examples/node/simple/), [`express`](examples/node/express/) (production-shaped)
- **Go** — [`examples/go/simple/`](examples/go/simple/) (static, on `varde-static`)
- **Rust** — [`examples/rust/simple/`](examples/rust/simple/) (glibc, on `varde-glibc`)
- **nginx** — [`examples/nginx/static-site/`](examples/nginx/static-site/)
- **redis** — [`examples/redis/simple/`](examples/redis/simple/)

The shortest possible case (a static binary):

```dockerfile
FROM ghcr.io/mathiasror/varde-static:latest   # a.k.a. varde-go
COPY app /app/app
# Inherits USER 1000:1000, WORKDIR /app, ENTRYPOINT ["/app/app"]
```

Pin to a digest (`...@sha256:…`) in production. Pick an arch explicitly with a
per-arch tag (`:21-musl-arm64`) if you ever need to.

## Building

Images are Linux-only and built on native runners. The repo builds **on macOS
hosts too**, but only through a Linux builder — Nix cannot produce a Linux image
from Darwin directly (use the nix-darwin
[`linux-builder`](https://nixos.org/manual/nixpkgs/stable/#sec-darwin-builder), or
just let CI build them). On a Linux host:

```bash
nix build .#image-jre-21-musl       # -> ./result  (a Docker-format image tarball)
nix build .#image-python-3_12-glibc # note: dots -> underscores, libc is part of the attr
docker load < result
# or push without a daemon:
skopeo copy docker-archive:result docker://ghcr.io/mathiasror/varde-jre:21-musl-amd64
```

List everything that exists: `nix eval --json .#ciMatrix` (each entry carries its
`libc`); `nix eval --json .#imageAliases` shows the go/rust aliases.

> **Binary cache.** CI publishes builds to the public [Cachix](https://cachix.org)
> cache `varde` — especially the musl variants, which aren't in `cache.nixos.org`
> and would otherwise compile from source. To pull them instead of building, add
> it as a substituter: `cachix use varde` (its public key is fetched
> automatically).

## Vulnerability scanning (Trivy)

A distroless image has **no OS package database**, so `trivy image` alone reports
no system packages. We close that gap with Nix's exact closure: for every image,
[`sbomnix`](https://github.com/tiiuae/sbomnix) emits a **CycloneDX SBOM with CPEs**
covering the system packages (glibc/musl, zlib, …) and the language runtime.

```bash
# System packages + runtime, via the SBOM:
nix run .#sbom-jre-21-musl -- sbom.cdx.json
trivy sbom sbom.cdx.json

# Your app's own dependencies, once the app image is built:
trivy image ghcr.io/mathiasror/your-app:tag
```

`trivy image` natively reads app dependencies from JARs, `node_modules`,
Python dist-info, and the build info embedded in **Go and Rust binaries** — so the
final app image is scannable too. CI runs both scans on every build; findings are
in the build log and the SBOM is uploaded as a build artifact. Scanning is
**report-only** for these base images (so they publish with their findings
visible); enforce hard gates in your *app* image, where you control the
dependency set.

> SARIF upload to the GitHub **Security** tab is wired up but non-fatal: on a
> **private** repo it needs GitHub Advanced Security, so it's skipped gracefully.
> Make the repo public (or enable GHAS) and the Security-tab integration lights up.

## Supply chain: signatures & SBOM attestations

Every published image is **keyless-signed** with [cosign](https://docs.sigstore.dev/)
using the GitHub Actions OIDC identity — no long-lived keys — and each per-arch
image carries a **CycloneDX SBOM attestation** (the closure SBOM above, attached
to the image so it travels with it, not just a CI artifact). Both are recorded in
the public Rekor transparency log. The multi-arch manifest lists are signed too,
so verifying by tag works.

```bash
# Verify a signature (the identity is this repo's build.yml workflow):
cosign verify \
  --certificate-identity-regexp '^https://github.com/mathiasror/varde/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/mathiasror/varde-jre:21

# The SBOM attestation is per-arch — resolve a platform digest, then verify it:
d=$(crane digest ghcr.io/mathiasror/varde-jre:21 --platform linux/amd64)
cosign verify-attestation --type cyclonedx \
  --certificate-identity-regexp '^https://github.com/mathiasror/varde/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  "ghcr.io/mathiasror/varde-jre@${d}" \
  | jq -r '.payload | @base64d | fromjson | .predicate' > sbom.cdx.json
```

## CI

[`.github/workflows/build.yml`](.github/workflows/build.yml) is fully
data-driven from the flake:

1. **setup** — reads `.#ciMatrix`, `.#latestTags`, and `.#imageAliases`, crosses
   every image/variant (including libc) with `amd64` + `arm64`.
2. **build** — native runners (`ubuntu-latest` / `ubuntu-24.04-arm`): build the
   image, generate + Trivy-scan the SBOM, scan the image, smoke-test it, push
   per-arch tags to GHCR (skipped on PRs).
3. **manifest** — assembles multi-arch lists per libc tag, the bare-version and
   `:latest` / `:latest-glibc` aliases, and the `varde-go` / `varde-rust` alias
   digests.

[`.github/workflows/e2e.yml`](.github/workflows/e2e.yml) builds every example on
top of a locally-built base, smoke-tests that the app runs, and asserts an
image-size budget ([`scripts/e2e.sh`](scripts/e2e.sh)).

Both `build` and `e2e` push/pull a shared **Cachix** cache so the from-source
musl variants are compiled once and reused across jobs, later runs, and the e2e
workflow (the first run is slow; subsequent ones are downloads).

Auth uses the built-in `GITHUB_TOKEN`. A weekly cron rebuilds against the latest
nixpkgs so published images pick up CVE fixes even when this repo is unchanged.

> **Cache setup, one-time:** create a free open-source cache named `varde` at
> [cachix.org](https://cachix.org) (keep it **public** so fork PRs and end users
> can read it), then add its write token as the repo secret `CACHIX_AUTH_TOKEN`
> (Settings → Secrets and variables → Actions). Without the secret, builds still
> work — they just don't get the cache speedup.

> **First publish, one-time step:** packages pushed by Actions are created
> **private** by default — even from a public repo — so anonymous `docker pull`
> would return 401 until you flip them. After the first successful build, set
> each `varde-*` package to **Public** once (GHCR → the package → *Package
> settings* → *Change visibility*) and connect it to this repository. Only then
> does the "just `docker pull`, no token" promise hold.

## Adding a new image

Adding `images/<name>.nix` is all it takes — the flake auto-discovers it and CI
picks it up with no workflow changes. A runtime/service module crosses each
version with the libc axis via `vardeLib.mkVariants`:

```nix
{ pkgs, vardeLib, lib }:
{
  description = "…";
  latest = "<tag>";                    # bare/:latest resolves to musl if built, else glibc
  variants = vardeLib.mkVariants pkgs {
    versions = {
      # `spec` is a function of the libc's package set (`pkgs` for glibc,
      # `pkgs.pkgsMusl` for musl), so the runtime is built for each libc. Each
      # "<tag>" becomes "<tag>-musl" and "<tag>-glibc". Restrict `libcs` to skip one.
      "<tag>" = {
        # libcs = [ "glibc" ];         # optional: e.g. no musl build upstream
        spec = p: {
          contents = [ (vardeLib.relocate p "…" "runtime" p.<pkg>) ];
          entrypoint = [ "/runtime/bin/…" ];
          cmd = [ … ];                 # optional
          env = [ "PATH=/runtime/bin" ];
          fhs = false;                 # true => add the libc's loader + libs for external native code
        };
      };
    };
  };
}
```

A compiled-binary base is a one-liner — reuse a shared spec:

```nix
{ pkgs, vardeLib, lib }:
{
  description = "…";
  latest = "latest";
  variants."latest" = vardeLib.staticSpec;   # or vardeLib.glibcSpec / vardeLib.muslSpec
}
```

The framework adds the non-root user, CA certs, tzdata, `/app`, `/tmp`, common
env, labels, and the SBOM app for free. Helpers live in
[`lib/default.nix`](lib/default.nix) (`relocate`, `mkLibcEnv`, `mkVariants`,
`buildImage`, `buildSbomApp`). See [`images/python.nix`](images/python.nix) for a
worked libc-axis module, or [`images/nginx.nix`](images/nginx.nix) for a service.
To publish a name as an alias of another image, add it to `imageAliases` in
[`flake.nix`](flake.nix).

## Layout

```
flake.nix                       # auto-discovers images/*.nix; packages, sbom apps, ciMatrix, imageAliases
lib/default.nix                 # scaffolding + mkLibcEnv, mkVariants, buildImage, buildSbomApp
images/<name>.nix               # one module per image (+ images/nginx.conf)
examples/<image>/<variant>/     # buildable "drop your app in" examples
scripts/e2e.sh                  # build examples on local bases, smoke + size budgets
.github/workflows/build.yml     # data-driven matrix build -> Trivy -> GHCR
.github/workflows/e2e.yml       # build + smoke-test the examples
.github/workflows/pages.yml     # deploy the landing page to GitHub Pages
site/                           # landing page (static, no build step)
docs/design.md                  # design notes
LICENSE                         # Apache-2.0
```

## License

varde's own build definitions — the Nix flake, the image modules under
`images/`, the shared library, the workflows, the examples, and the site — are
licensed under the [Apache License 2.0](LICENSE).

Each published image also bundles third-party software under its own license:
the language runtimes, servers, and system libraries it packages (glibc or musl,
the Temurin JRE, CPython, Node.js, nginx, Redis, and their dependencies, for
example) are distributed under their respective upstream licenses. `nix build`
records the exact closure and the generated SBOM lists every component, so the
full contents are always inspectable.
