# varde

Minimal, **distroless** container base images built with Nix. Each image carries
only what an app needs to run — the language runtime (or, for compiled
languages, just the libs a binary links against) and nothing else: **no shell,
no package manager, no coreutils, no busybox** — and every image runs as an
unprivileged user.

> A *varde* (Norwegian for a *cairn*) is a small stack of stones that marks a
> trail. These are the smallest stacks you need to run an app, and nothing more.

## Images

| Image | Tags | Runs | Drop-in contract |
| --- | --- | --- | --- |
| `varde-jre` | `17` `21` `25` `latest`(=21) | JVM apps (Java/Kotlin) | `COPY app-all.jar /app/app.jar` (fat jar) |
| `varde-python` | `3.11` `3.12` `3.13` `latest`(=3.13) | Python apps | `COPY` interpreter deps + code into `/app` |
| `varde-node` | `22` `24` `latest`(=24) | Node.js apps | `COPY node_modules` + code into `/app` |
| `varde-go` | `latest` | static Go binaries (`CGO_ENABLED=0`) | `COPY app /app/app` |
| `varde-rust` | `latest` | dynamically-linked Rust binaries | `COPY app /app/app` |

Each is published to **GHCR** under `ghcr.io/mathiasror/<image>`, multi-arch
(`amd64` + `arm64`), plus explicit per-arch tags (e.g. `:21-amd64`).

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

Compiled-language and native-dependency images (`python`, `node`, `rust`) also
ship a glibc + libstdc++ layout at standard FHS paths (`/lib64/ld-linux-*.so`,
`/lib`) so **externally-compiled** native code — manylinux wheels, native node
addons, a normal `cargo build` binary — finds its loader and libraries. `varde-go`
is scratch-like (static binaries need none of this).

## Using the images

The integration is "drop your app in." Because there is no shell, the entrypoint
runs your app directly — bring a self-contained artifact (a fat JAR, a binary, or
code plus its already-installed dependencies). Full, multi-stage examples:

- [`examples/jre.Dockerfile`](examples/jre.Dockerfile)
- [`examples/python.Dockerfile`](examples/python.Dockerfile)
- [`examples/node.Dockerfile`](examples/node.Dockerfile)
- [`examples/go.Dockerfile`](examples/go.Dockerfile)
- [`examples/rust.Dockerfile`](examples/rust.Dockerfile)

The shortest possible case (Go static binary):

```dockerfile
FROM ghcr.io/mathiasror/varde-go:latest
COPY app /app/app
# Inherits USER 1000:1000, WORKDIR /app, ENTRYPOINT ["/app/app"]
```

Pin to a digest (`...@sha256:…`) in production. Pick an arch explicitly with a
per-arch tag (`:21-arm64`) if you ever need to.

## Building

Images are Linux-only and built on native runners. The repo builds **on macOS
hosts too**, but only through a Linux builder — Nix cannot produce a Linux image
from Darwin directly (use the nix-darwin
[`linux-builder`](https://nixos.org/manual/nixpkgs/stable/#sec-darwin-builder), or
just let CI build them). On a Linux host:

```bash
nix build .#image-jre-21        # -> ./result  (a Docker-format image tarball)
nix build .#image-python-3_12   # note: dots become underscores in attr names
docker load < result
# or push without a daemon:
skopeo copy docker-archive:result docker://ghcr.io/mathiasror/varde-jre:21-amd64
```

List everything that exists: `nix eval --json .#ciMatrix`.

## Vulnerability scanning (Trivy)

A distroless image has **no OS package database**, so `trivy image` alone reports
no system packages. We close that gap with Nix's exact closure: for every image,
[`sbomnix`](https://github.com/tiiuae/sbomnix) emits a **CycloneDX SBOM with CPEs**
covering the system packages (glibc, zlib, …) and the language runtime.

```bash
# System packages + runtime, via the SBOM:
nix run .#sbom-jre-21 -- sbom.cdx.json
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

## CI

[`.github/workflows/build.yml`](.github/workflows/build.yml) is fully
data-driven from the flake:

1. **setup** — reads `.#ciMatrix` and `.#latestTags`, crosses every image/variant
   with `amd64` + `arm64`.
2. **build** — native runners (`ubuntu-latest` / `ubuntu-24.04-arm`): build the
   image, generate + Trivy-scan the SBOM, scan the image, push per-arch tags to
   GHCR (skipped on PRs).
3. **manifest** — assembles multi-arch `:<tag>` lists and per-image `:latest`.

Auth uses the built-in `GITHUB_TOKEN`. A weekly cron rebuilds against the latest
nixpkgs so published images pick up CVE fixes even when this repo is unchanged.

> **First publish, one-time step:** packages pushed by Actions are created
> **private** by default — even from a public repo — so anonymous `docker pull`
> would return 401 until you flip them. After the first successful build, set
> each `varde-*` package to **Public** once (GHCR → the package → *Package
> settings* → *Change visibility*) and connect it to this repository. Only then
> does the "just `docker pull`, no token" promise hold.

## Adding a new image

Adding `images/<name>.nix` is all it takes — the flake auto-discovers it and CI
picks it up with no workflow changes. A module is:

```nix
{ pkgs, vardeLib, lib }:
{
  description = "…";
  latest = "<tag>";                 # which variant publishes as :latest
  variants = {
    "<tag>" = {
      contents = [ … ];             # store paths merged at image root (optional)
      entrypoint = [ "/runtime/bin/…" ];
      cmd = [ … ];                  # optional
      env = [ "PATH=/runtime/bin" ];# optional, extra env
      fhs = false;                  # true => add FHS glibc/libstdc++ for external native code
    };
  };
}
```

The framework adds the non-root user, CA certs, tzdata, `/app`, `/tmp`, common
env, labels, and the SBOM app for free. Helpers live in
[`lib/default.nix`](lib/default.nix) (`relocate`, the FHS layout, `buildImage`,
`buildSbomApp`). See [`images/jre.nix`](images/jre.nix) for a worked example.

Planned next: service images such as `nginx` and `redis` (a packaged binary from
nixpkgs + its runtime closure, same module shape).

## Layout

```
flake.nix                     # auto-discovers images/*.nix; exposes packages, sbom apps, ciMatrix
lib/default.nix               # shared scaffolding + buildImage / buildSbomApp
images/<name>.nix             # one module per image
examples/<name>.Dockerfile    # "drop your app in" examples
.github/workflows/build.yml   # data-driven matrix build -> Trivy -> GHCR
.github/workflows/pages.yml   # deploy the landing page to GitHub Pages
site/                         # landing page (static, no build step)
docs/design.md                # design notes
LICENSE                       # Apache-2.0
```

## License

varde's own build definitions — the Nix flake, the image modules under
`images/`, the shared library, the workflows, and the site — are licensed under
the [Apache License 2.0](LICENSE).

Each published image also bundles third-party software under its own license:
the language runtimes and system libraries it packages (glibc, the Temurin JRE,
CPython, Node.js, and their dependencies, for example) are distributed under
their respective upstream licenses. `nix build` records the exact closure and
the generated SBOM lists every component, so the full contents are always
inspectable.
