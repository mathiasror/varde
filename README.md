# varde

Minimal, **distroless** container base images built with Nix. Each image carries
only what an app needs to run — the language runtime (or, for compiled
languages, just the libs a binary links against) and nothing else: **no
package manager, no coreutils, and no shell in production images** (the one
exception, a static `ash` in `varde-postgres` that `initdb` requires, is
described [below](#libc-musl-by-default-glibc-on-request)) — and every image
runs as an unprivileged user. Where there's a choice of C library, images
default to **musl** (a smaller codebase and CVE history), with **glibc** one tag
away.

> A *varde* (Norwegian for a *cairn*) is a small stack of stones that marks a
> trail. These are the smallest stacks you need to run an app, and nothing more.

## Images

### Quick start

```bash
docker pull ghcr.io/mathiasror/varde-python:3.13
docker run --rm ghcr.io/mathiasror/varde-python:3.13 -c 'print("varde ok")'
# Verify the signature against the one identity that publishes:
cosign verify \
  --certificate-identity https://github.com/mathiasror/varde/.github/workflows/build.yml@refs/heads/main \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/mathiasror/varde-python:3.13
```

To build on one, see [Using the images](#using-the-images); to verify SBOM,
VEX and provenance, see
[Supply chain](#supply-chain-signatures-sbom--provenance).

**Language runtimes**

| Image | Tags | Runs | Drop-in contract |
| --- | --- | --- | --- |
| `varde-jre` | `17`* `21` `25` `latest`(=21) | JVM apps (Java/Kotlin) | `COPY app.jar /app/app.jar` (fat/boot jar) |
| `varde-python` | `3.11` `3.12` `3.13` `latest`(=3.13) | Python apps | `COPY` interpreter deps + code into `/app` |
| `varde-node` | `22` `24` `latest`(=24) | Node.js apps | `COPY node_modules` + code into `/app` |
| `varde-php` | `8.3` `8.4` `8.5` `latest`(=8.5) | PHP apps (cli + `php-fpm`) | `COPY` code + `vendor/` into `/app` |

**Services**

| Image | Tags | Runs | Drop-in contract |
| --- | --- | --- | --- |
| `varde-nginx` | `latest` | static sites (non-root, listens on `:8080`) | `COPY site/ /app/` |
| `varde-redis` | `latest` | Redis server | run as-is (loopback / `docker exec` clients only — Redis protected mode denies remote clients until a password or config is set), or pass a `redis.conf` via `CMD`; for `-p 6379:6379` use e.g. `CMD ["--requirepass", "<secret>"]` |
| `varde-postgres` | `16` `17` `18` `latest`(=18) | PostgreSQL server | one-time `initdb` via `--entrypoint` against a volume at `/app`, then run |
| `varde-mysql` | `8.4`* `latest`(=8.4) | MySQL 8.4 LTS server | one-time `--initialize-insecure` run, then run as-is |
| `varde-rabbitmq` | `latest` | RabbitMQ broker (shell-free Erlang boot) | run as-is; `rabbitmq.conf` + `enabled_plugins` via `COPY` to `/app` |
| `varde-memcached` | `latest` | Memcached server | run as-is (`:11211`), or pass flags via `CMD`, e.g. `CMD ["-m", "256"]` |

**Compiled-binary bases** (bring your own binary at `/app/app`)

| Image | Tags | Runs |
| --- | --- | --- |
| `varde-static` | `latest` | any **static** binary — Go `CGO_ENABLED=0`, musl-static Rust, static C/Zig |
| `varde-glibc` | `latest` | any **glibc-dynamic** binary — a default `cargo build`, cgo Go, C/C++ |
| `varde-musl` | `latest` | any **musl-dynamic** binary |

`varde-go` and `varde-rust` are published as **aliases** for discoverability:
`varde-go` → `varde-static`, `varde-rust` → `varde-glibc` (the same digests).
Each alias carries copies of its source's per-arch signature and all four
attestations (SBOM, OpenVEX, vulnerability scan, SLSA provenance; the same
Rekor entries), so the verification recipe below works against the alias name
too.

Each is published to **GHCR** under `ghcr.io/mathiasror/<image>`, multi-arch
(`amd64` + `arm64`).

Tags ending in `-staging` (e.g. `varde-jre:21-staging`) are internal CI
pipeline tags, overwritten on every publish run; do not use them.

### libc: musl by default, glibc on request

Every runtime/service image is built for both C libraries. **The bare tag is
musl** (the default); append **`-glibc`** to opt in to glibc:

```dockerfile
# musl (default)
FROM ghcr.io/mathiasror/varde-python:3.13
# glibc (opt-in)
FROM ghcr.io/mathiasror/varde-python:3.13-glibc
```

musl is the default because a smaller libc means less to patch and a smaller
attack surface. Reach for `-glibc` when something needs it — a wheel with only
manylinux (glibc) binaries, a native addon built against glibc, or a prebuilt
dependency that assumes glibc. Per-arch tags are libc-qualified, e.g.
`:21-musl-arm64` or `:3.13-glibc-amd64`. The older bare-version per-arch tags
(`varde-jre`, `varde-python` and `varde-node` `:<ver>-amd64` / `:<ver>-arm64`)
predate the libc split, when every image was glibc, so CI keeps them on the
**glibc** build (`:<ver>-glibc-<arch>`), not on the bare tag's musl. Prefer
the libc-qualified form so the libc is explicit.

*`varde-jre:17` is **glibc-only** — Adoptium ships no aarch64 Alpine/musl JRE for
JDK 17; `:21` and `:25` default to musl. `varde-mysql` is **glibc-only** — musl
MySQL is not buildable from nixpkgs (its protobuf/abseil pin is marked broken
on musl), so its bare tags are the glibc build. `varde-static` carries no libc
(static binaries embed their own), so it has no `-musl`/`-glibc` split.

`varde-postgres` is the **one exception to "no shell"**: it ships a minimal
static `ash` at `/bin/sh` (Nix's own busybox-sandbox-shell — a single binary,
no other applets) because PostgreSQL's `initdb` bootstraps through libc
`popen`/`system`, which hardcode `/bin/sh`. Every other production image is
shell-free.

### `-debug` tags: for troubleshooting only

Every tag has a **`-debug`** sibling, for example `varde-python:3.13-debug`,
`:3.13-glibc-debug`, `varde-static:latest-debug` or `varde-go:latest-debug`. It
is the same image, with the same layers, user (`1000:1000`), entrypoint and cmd,
plus a static **busybox** (`sh`, `ls`, `ps`, `wget`, `netstat`, …) at `/busybox`
on `PATH`. It is signed and attested like the production tag, and its scan
includes busybox.

> **Never run a `-debug` tag in production.** It puts back exactly the shell
> and userland that varde leaves out. Use it to troubleshoot: as a
> `kubectl debug` ephemeral container, as a sidecar that shares a container's
> namespaces, or in place of the production tag on a throwaway copy. See
> **[docs/debugging.md](docs/debugging.md)**.

The "no shell" guarantees below apply to the production tags, which never
contain the busybox layer. There are no per-arch `-debug` tags; pull a specific
platform with `--platform`.

### Every image guarantees

| Property | Value |
| --- | --- |
| User | `1000:1000` (`app`, non-root) |
| Working directory | `/app` (owned by `1000:1000`) |
| Shell / package manager | **none** (except `varde-postgres`'s static `ash`, above; `-debug` tags add busybox, see above) |
| TLS | CA bundle at `/etc/ssl/certs/ca-certificates.crt` (`SSL_CERT_FILE` set): nixpkgs' Mozilla-derived `cacert` minus the roots varde distrusts (currently the eMudhra/Sectigo roots behind the October 2026 intermediate key compromise; a build check proves the compromised chains are rejected, see [`lib/distrust`](lib/distrust)). Node reads this bundle, and the JRE's `cacerts` is generated from it |
| Timezones | tzdata at `/usr/share/zoneinfo` (`TZDIR` set) |
| Writable paths | `/app`, `/tmp` (sticky) |
| Scanning | per-image CycloneDX SBOM with NVD CPEs, scanned with grype; the signed result is attested on the image (see below) |

The shell/package-manager guarantee is **enforced at build time** by a
deny-list closure check ([`lib/default.nix`](lib/default.nix)): any image
build fails whose runtime closure contains a store path named like a known
shell (`bash`, `dash`, `busybox`, `mksh`, `zsh`, `toybox`, `ksh`, `fish`,
`tcsh`, `yash`, `nushell`, …), `coreutils`, a runtime's package-manager output
(`npm`, `pip`), or a `-dev` output. Postgres's disclosed static `ash` is the
sole, explicit exemption, pinned to that exact derivation. The `-debug` tags
don't loosen it. Their production layers pass this same check unchanged, and
the busybox they add is checked separately, exempting only that one busybox
derivation. The guard is only
as strong as its list — a shell nixpkgs names differently would pass — but a
nixpkgs bump can never silently ship anything on it.

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
- **PHP** — [`examples/php/simple/`](examples/php/simple/) (cli; the image also ships `php-fpm` — see the example README)
- **nginx** — [`examples/nginx/static-site/`](examples/nginx/static-site/)
- **redis** — [`examples/redis/simple/`](examples/redis/simple/)
- **postgres** — [`examples/postgres/simple/`](examples/postgres/simple/) (explicit `initdb`, volume at `/app`)
- **mysql** — [`examples/mysql/simple/`](examples/mysql/simple/) (`--initialize-insecure`, then serve)
- **rabbitmq** — [`examples/rabbitmq/simple/`](examples/rabbitmq/simple/) (config + plugins via `COPY`)
- **memcached** — [`examples/memcached/simple/`](examples/memcached/simple/)

To get a shell next to a running app without adding one to it, see
[docs/debugging.md](docs/debugging.md).

The shortest possible case (a static binary):

```dockerfile
# a.k.a. varde-go
FROM ghcr.io/mathiasror/varde-static:latest
COPY app /app/app
# Inherits USER 1000:1000, WORKDIR /app, ENTRYPOINT ["/app/app"]
```

Pin to a digest (`...@sha256:…`) in production. Pick an arch explicitly with a
per-arch tag (`:21-musl-arm64`) if you ever need to. Tags are rebuilt weekly
against the latest nixpkgs (see [CI](#ci)), so a tag picks up CVE fixes but a
pinned digest never does: let Renovate or Dependabot bump the digest.

### Without a shell

- **Health checks**: use the exec form with a binary the image ships, e.g.
  `HEALTHCHECK CMD ["/runtime/bin/pg_isready", "-U", "postgres"]` or
  `["/runtime/bin/mysqladmin", "-u", "root", "ping"]` (the probes the
  [postgres](examples/postgres/simple/README.md) and
  [mysql](examples/mysql/simple/README.md) examples run with `docker exec`).
  There is no `curl`: give an app an HTTP endpoint for the orchestrator's
  probe (the [express example](examples/node/express/)'s `/healthz`), or probe
  with the runtime itself, e.g.
  `["/runtime/bin/python3", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/healthz')"]`.
  Shell-form `HEALTHCHECK CMD …`, `RUN`, and `docker exec … sh` fail.
- **Debugging**: attach tools from outside instead of adding them to the
  image: `docker debug <container>` (Docker Desktop), or
  `kubectl debug -it <pod> --image=busybox --target=<container>`, which shares
  the target's process namespace (its filesystem is under `/proc/1/root`).
- **Kubernetes**: `USER` is numeric (`1000:1000`), so `runAsNonRoot: true`
  works without setting `runAsUser`.

### Size budgets

[`scripts/e2e.sh`](scripts/e2e.sh) fails CI if an example image (base plus the
example app, uncompressed, as `docker image inspect` reports it) grows past its
budget. These are upper limits, not measured sizes:

| Example | Base | Budget |
| --- | --- | --- |
| `go/simple` | `varde-static` | 10 MB |
| `memcached/simple` | `varde-memcached` | 15 MB |
| `nginx/static-site` | `varde-nginx` | 30 MB |
| `redis/simple` | `varde-redis` | 35 MB |
| `rust/simple` | `varde-glibc` | 55 MB |
| `rabbitmq/simple` | `varde-rabbitmq` | 105 MB |
| `postgres/simple` | `varde-postgres:18` | 115 MB |
| `python/simple`, `requirements-venv`, `uv` | `varde-python:3.13` | 185–190 MB |
| `node/simple`, `express` | `varde-node:24` | 215–220 MB |
| `php/simple` | `varde-php:8.5` | 230 MB |
| `jre/spring-boot-gradle` | `varde-jre:21` | 320 MB |
| `mysql/simple` | `varde-mysql:8.4` (glibc) | 385 MB |

All bases are the musl build unless noted.

### Not supported

- **Architectures** other than `amd64` and `arm64`.
- **musl** for `varde-jre:17` and `varde-mysql` (glibc-only, see above).
- **Shell or `-dev` variants** of any production image; postgres's static
  `/bin/sh` is the only shell shipped.
- **Package managers at runtime**: no `npm` in node, no `pip` (or `ensurepip`)
  in python, no `composer`, `pear` or `pecl` in php. Install dependencies in a
  builder stage and `COPY` them in (see the examples).
- **PHP** `ldap` extension (dropped on both libcs) and `mail()` (there is no
  sendmail; it fails cleanly, so send over SMTP from the app).
- **End-of-life runtimes**, e.g. Node.js 20.
- **Trivy, Docker Scout and Snyk** as scanners: they cannot see Nix packages
  (see [Scanning varde images](#scanning-varde-images)).

## Building

Images are Linux-only and built on native runners. The repo builds **on macOS
hosts too**, but only through a Linux builder — Nix cannot produce a Linux image
from Darwin directly. Use nixpkgs'
[`darwin.linux-builder`](https://nixos.org/manual/nixpkgs/stable/#sec-darwin-builder)
(or nix-darwin's `nix.linux-builder`), or just let CI build them. On a Linux
host:

```bash
nix build .#image-jre-21-musl       # -> ./result  (a Docker-format image tarball)
nix build .#image-python-3_12-glibc # note: dots -> underscores, libc is part of the attr
docker load < result
# or push to your own namespace without a daemon:
skopeo copy docker-archive:result docker://ghcr.io/YOUR_USER/varde-jre:21-musl-amd64
```

The flake only defines packages for `x86_64-linux` and `aarch64-linux`, so on
macOS the short `.#image-…` form does not exist; name the Linux system
explicitly and the build goes to the Linux builder:

```bash
nix build .#packages.aarch64-linux.image-jre-21-musl
```

List everything that exists: `nix eval --json .#ciMatrix` (each entry carries its
`libc`); `nix eval --json .#imageAliases` shows the go/rust aliases.

> **Binary cache.** CI publishes builds to the public [Cachix](https://cachix.org)
> cache `varde` — especially the musl variants, which aren't in `cache.nixos.org`
> and would otherwise compile from source. To pull them instead of building, run
> `cachix use varde`, or add to your Nix config:
> ```
> extra-substituters = https://varde.cachix.org
> extra-trusted-public-keys = varde.cachix.org-1:oUZD/OJtc/pTMrpe/p7Ax/2eLhbphON1O5mWRbvWa84=
> ```

## Scanning varde images

> **Trivy, Docker Scout and Snyk report these images clean — that is a false
> negative, not a clean image.** All three find vulnerabilities through a
> distro package database (apk/dpkg/rpm) or language-ecosystem package URLs,
> and none of them knows Nix: Trivy has no Nix ecosystem and skips `pkg:nix`,
> `pkg:generic` and CPE-only components even in an SBOM you hand it; Docker
> Scout matches purls only; `snyk container test` reads the OS package
> database the image does not have. So they see zero packages and report 0
> vulnerabilities whatever ships (on 2026-10-17, `trivy image` on
> `varde-postgres:17` found 0 where grype found 40; given a CycloneDX SBOM
> with a known-vulnerable openssl, trivy still finds nothing). Use grype, or
> Dependency-Track on the attested SBOM (both below). Trivy remains useful on
> these images for its secret scanning. Varde does not fake distro package
> URLs to make them light up. The upstream gap: NixOS has no vulnerability
> feed with a "fixed" state that Trivy could consume
> ([aquasecurity/trivy#1673](https://github.com/aquasecurity/trivy/issues/1673),
> [NixOS/nix-security-tracker#978](https://github.com/NixOS/nix-security-tracker/issues/978)).

### Quick scan: grype on the image

Scan a varde image like any other image — with
[grype](https://github.com/anchore/grype):

```bash
grype ghcr.io/mathiasror/varde-postgres:17
```

A distroless image has **no OS package database**, but a Nix image keeps every
package under `/nix/store/<hash>-<name>-<version>`, and grype (via syft's Nix
cataloger) reads those paths straight out of the image layers — glibc/musl,
openssl, zlib, the language runtime, everything in the closure — and matches
them against NVD by CPE. The same command covers your app's own dependencies
once you build on top: grype natively reads JARs, `node_modules`, Python
dist-info, and the build info embedded in **Go binaries** (and Rust binaries
built with `cargo auditable`).

### The CI-equivalent scan: attested SBOM + VEX

For the most complete result, scan the **attested SBOM** CI publishes with
every image, with the image's **OpenVEX** applied — exactly what CI runs. The
SBOM is the same syft inventory plus hand-authored components that carry the
exact identity NVD files CVEs under (`gnu:glibc`, `musl-libc:musl`,
`oracle:openjdk`, `python_software_foundation:cpython`, …): the Nix cataloger
guesses `vendor = product = pname`, and a wrong vendor matches nothing,
silently. The VEX is explained under
[The OpenVEX attestation](#the-openvex-attestation-fixed-not-affected-and-affected-cves).

The attestations live on the **per-arch digests** (the things actually built),
not on the multi-arch tag, so resolve a platform digest first. Images are
reproducible, so a digest that did not change between weekly runs collects
one attestation of each type per run; the `jq -s … max_by` keeps the newest.
The variables set here (`IMG`, `d`, `ID`, `ISSUER`) are reused by every
command further down:

```bash
IMG=ghcr.io/mathiasror/varde-postgres
d=$(crane digest "$IMG:17" --platform linux/amd64)
ID=https://github.com/mathiasror/varde/.github/workflows/build.yml@refs/heads/main
ISSUER=https://token.actions.githubusercontent.com

cosign verify-attestation --type cyclonedx \
  --certificate-identity "$ID" --certificate-oidc-issuer "$ISSUER" "$IMG@$d" \
  | jq -s '[.[].payload | @base64d | fromjson | .predicate] | max_by(.metadata.timestamp)' > sbom.cdx.json
cosign verify-attestation --type openvex \
  --certificate-identity "$ID" --certificate-oidc-issuer "$ISSUER" "$IMG@$d" \
  | jq -s '[.[].payload | @base64d | fromjson | .predicate] | max_by(.timestamp)' > vex.openvex.json

grype --vex vex.openvex.json sbom:sbom.cdx.json
```

Or generate the SBOM from the flake on Linux. Image tarballs are not in the
Cachix cache, so the app assembles the tarball locally from the cached store
paths (seconds when the cache is warm) and reads it:

```bash
nix run .#sbom-jre-21-musl -- sbom.cdx.json
grype sbom:sbom.cdx.json
```

### CI's own result: the vulnerability-scan attestation

CI scans every image's SBOM with grype on every build, guarded by a known-CVE
canary fixture: if grype ever parses the fixture to zero findings (a broken
scanner or DB), the build fails instead of every image reporting clean.
Scanning is **report-only** for these base images (so they publish with their
findings visible); enforce hard gates in your *app* image, where you control
the dependency set. CPE matching of Nix store contents against NVD is
best-effort, and it compares upstream versions — a CVE nixpkgs fixed with a
patch still shows until the version moves — so expect occasional false
positives and misses compared to a distro package database. Findings are in
the build log, in a build artifact (with the SBOM and VEX), and on the image
itself.

Each per-arch image carries CI's grype result as a signed
**vulnerability-scan attestation** (cosign's
[`vuln` predicate](https://github.com/sigstore/cosign/blob/main/specs/COSIGN_VULN_ATTESTATION_SPEC.md),
`https://cosign.sigstore.dev/attestation/vuln/v1`): the grype version, the
vulnerability-DB version and build time, the run that scanned, and grype's
full JSON output (`matches`, plus the VEX-suppressed `ignoredMatches`). It is
a **point-in-time snapshot** — findings as of that DB build, not a live
verdict; CVEs published since then are not in it, so rescan (above) for
today's view. With `$IMG`, `$d`, `$ID` and `$ISSUER` from the previous block:

```bash
cosign verify-attestation --type vuln \
  --certificate-identity "$ID" --certificate-oidc-issuer "$ISSUER" "$IMG@$d" \
  | jq -s '[.[].payload | @base64d | fromjson | .predicate] | max_by(.metadata.scanFinishedOn)' > vuln.json
jq '{scanned: .metadata.scanFinishedOn, grype: .scanner.version, db: .scanner.db.version,
     matches: (.scanner.result.matches | length),
     vex_suppressed: (.scanner.result.ignoredMatches | length)}' vuln.json
jq -r '.scanner.result.matches[] | "\(.vulnerability.id) \(.vulnerability.severity) \(.artifact.name)@\(.artifact.version)"' vuln.json
```

### Dependency-Track

[Dependency-Track](https://dependencytrack.org/) works from the attested
CycloneDX SBOM: its NVD analyzer matches the components' CPEs, so it sees what
grype sees and keeps re-evaluating the SBOM as new CVEs arrive. Upload the
`sbom.cdx.json` extracted above (`DT_URL` and an API key with BOM upload
permission are your instance's):

```bash
curl -fsS -X POST "$DT_URL/api/v1/bom" -H "X-Api-Key: $DT_API_KEY" \
  -F autoCreate=true -F projectName=varde-postgres -F projectVersion=17-amd64 \
  -F bom=@sbom.cdx.json
```

Dependency-Track imports CycloneDX VEX, not OpenVEX, so the varde OpenVEX
statements are not applied there; triage those findings against
`vex.openvex.json` (or `vex/statements.nix`) by hand.

### The OpenVEX attestation: fixed, not-affected and affected CVEs

grype compares upstream versions, so a CVE that nixpkgs fixed with a patch,
without bumping the version, still shows up, and so do CVEs filed against a
different product or a component that varde does not ship. Each image carries
an **OpenVEX attestation** that records those cases, and also the CVEs that
*do* apply, with what to do about them. It holds a `fixed` statement for every
CVE a nixpkgs patch in the image is named after, plus the hand-reviewed
`not_affected`, `fixed` and `affected` statements in
[`vex/statements.nix`](vex/statements.nix), each with its evidence. It is
generated from the same commit as the image ([`lib/vex.nix`](lib/vex.nix)),
and CI's scan applies it. To apply it yourself, extract it as in
[the CI-equivalent scan](#the-ci-equivalent-scan-attested-sbom--vex), then:

```bash
grype --vex vex.openvex.json sbom:sbom.cdx.json   # or: grype --vex vex.openvex.json "$IMG@$d"
```

grype moves `not_affected` and `fixed` matches to `ignoredMatches` (see
`-o json`) rather than deleting them, so you can always audit what was
suppressed and why.

A statement can be scoped to some images (`images` in `vex/statements.nix`),
because the same library can be reachable in one image and dead code in
another. CVE-2026-107778 (krb5 `krb5_rd_cred`) is the example: it is
reachable only through the GSS-API acceptor, so it is `not_affected` in
`varde-php` and `varde-mysql`, which use krb5 only as an initiator, and
`affected` in `varde-postgres`, which accepts GSSAPI on any TCP connection
once a keytab is provided (the image ships none). An `affected` statement
carries an `action_statement` with the mitigation. It suppresses nothing:
grype still reports the match. List an image's affected CVEs and their
actions:

```bash
jq -r '.statements[] | select(.status == "affected") | "\(.vulnerability.name) \(.products[0]["@id"]): \(.action_statement)"' vex.openvex.json
```

From a checkout, `nix eval --json .#vex.x86_64-linux.sbom-postgres-17-glibc`
prints the same document for any `sbomName` in `.#ciMatrix`. A statement is
varde's claim, not upstream's, so review `vex/statements.nix` if your policy
requires it.

> SARIF upload to the GitHub **Security** tab is wired up but non-fatal — scan
> findings land under **Security → Code scanning** per image/arch. (On a private
> fork this needs GitHub Advanced Security and is skipped gracefully.)

## Supply chain: signatures, SBOM & provenance

Every published image is **keyless-signed** with [cosign](https://docs.sigstore.dev/)
using the GitHub Actions OIDC identity — no long-lived keys — and each per-arch
image carries a **CycloneDX SBOM attestation** (the closure SBOM above, attached
to the image so it travels with it, not just a CI artifact), the **OpenVEX** and
**vulnerability-scan** attestations described under
[Scanning varde images](#scanning-varde-images), and a **SLSA
build-provenance attestation** (builder, source commit, invocation). Signatures
and attestations are recorded in the public Rekor transparency log; the multi-arch
manifest lists are signed too, so verifying by tag works. Per-arch tags are
moved onto a digest only *after* its signature and all four attestations are
attached and verified, so a tag never points at an unsigned image. The
`varde-go` / `varde-rust` aliases get the per-arch signature and attestations
copied into their own repo (and re-verified there) before their lists are
signed and tagged, so every command below works with the alias name as well.

The one signing identity is `build.yml` **on `main`**
(`https://github.com/mathiasror/varde/.github/workflows/build.yml@refs/heads/main`,
issuer `https://token.actions.githubusercontent.com`) — publishing is refused
from any other ref — so verify against that exact identity rather than a
repo-wide pattern (which would also accept other workflows and branches).
With `IMG`, `d`, `ID` and `ISSUER` set as in
[the CI-equivalent scan](#the-ci-equivalent-scan-attested-sbom--vex):

```bash
# Verify the signature on the multi-arch tag:
cosign verify --certificate-identity "$ID" --certificate-oidc-issuer "$ISSUER" "$IMG:17"

# Verify SLSA build provenance on the per-arch digest (--bundle-from-oci reads
# the attestation attached to the image in GHCR, the copy CI gates on, rather
# than the GitHub attestations API):
gh attestation verify "oci://$IMG@$d" --repo mathiasror/varde --cert-identity "$ID" --bundle-from-oci
```

The SBOM, OpenVEX and vulnerability-scan attestations are verified and
extracted by the `cosign verify-attestation` commands in
[the CI-equivalent scan](#the-ci-equivalent-scan-attested-sbom--vex) and
[CI's own result](#cis-own-result-the-vulnerability-scan-attestation): each
fails unless the attestation is signed by that identity.

## CI

[`.github/workflows/build.yml`](.github/workflows/build.yml) is fully
data-driven from the flake:

1. **setup** — reads `.#ciMatrix`, `.#latestTags`, and `.#imageAliases`, crosses
   every image/variant (including libc) with `amd64` + `arm64`. A PR builds
   only the images its diff touches (a shared input such as `lib/`,
   `flake.nix`, `flake.lock` or `build.yml` falls back to the full matrix);
   push and dispatch always build everything.
2. **build** — native runners (`ubuntu-latest` / `ubuntu-24.04-arm`): build the
   image, generate the SBOM, grype-scan it (behind a known-CVE canary),
   Trivy-scan the image filesystem for secrets, smoke-test it, push it to GHCR by digest,
   sign + attest + verify it, and only then move the per-arch tag onto that
   digest (all skipped on PRs). The same leg does the same for the variant's
   `-debug` sibling, except that the `-debug` sibling gets no per-arch tag.
3. **manifest** — assembles multi-arch lists per libc tag, the bare-version and
   `:latest` / `:latest-glibc` aliases, and the `varde-go` / `varde-rust` alias
   digests (each with its `-debug` twin) — from this run's verified per-arch
   digests, per image:tag pair — then moves the pre-split `:<ver>-<arch>` tags
   that still exist onto the `-glibc` children. A
   leg that failed or timed out holds back only the lists that need it (the
   job names them and goes red); every other pair is still refreshed.

Publishing happens from `main` only: `push` is filtered to `main` and a
`workflow_dispatch` from any other ref fails in `setup`.

[`.github/workflows/e2e.yml`](.github/workflows/e2e.yml) builds every example on
top of a locally-built base, smoke-tests that the app runs, and asserts an
image-size budget ([`scripts/e2e.sh`](scripts/e2e.sh)): on PRs that touch an
input; on `main` after every successful *push* `build-image` run (a merge that
rebuilds the images; an examples-only merge is covered by its PR-time run),
warm from the Cachix cache that build just populated; and inside the weekly
bump, before it lands (below). The weekly publish itself does not chain into
e2e: it is dispatched with `GITHUB_TOKEN`, and GitHub raises no `workflow_run`
event for a run started that way.

Both `build` and `e2e` push/pull a shared **Cachix** cache so the from-source
musl variants are compiled once and reused across jobs, later runs, and the e2e
workflow (the first run is slow; subsequent ones are downloads).

Auth uses the built-in `GITHUB_TOKEN`. A weekly job
([`bump-lock.yml`](.github/workflows/bump-lock.yml)) validates a nixpkgs bump
before it lands:

1. **bump** — `nix flake update nixpkgs`, then commit the new lock to the
   `bump/flake-lock` side branch (main's head plus the lock; a GitHub-signed
   commit).
2. **verify** — run `build.yml` with `verify_only` (the full matrix: build,
   SBOM, scans, smoke tests; no sign, push or tag) and `e2e.yml` on that
   commit.
3. **land** — only if both are green, fast-forward `main` to that exact commit
   and dispatch the publishing `build.yml` run.

A nixpkgs that breaks a build therefore leaves `main` and the published images
on last week's lock, with a red bump run to look at. (An unchanged lock skips
verify and dispatches the weekly rebuild directly, for a fresh scan and
attestations.) Published images pick up
CVE fixes, *and* every published image corresponds to a commit of this repo
whose lock reproduces it.

[`rebuild-watchdog.yml`](.github/workflows/rebuild-watchdog.yml) runs every 3
hours. It re-runs the failed jobs of the newest `bump-lock` run on `main` and
of the newest publishing (push or dispatch) `build-image` run on `main`, up to
3 attempts in total, since most red weeks are cache-cold timeouts or flaky
dependency tests; cancelled runs are left alone. It also checks freshness for
each image's default tag in `.#latestTags`: the linux/amd64 image must carry a
verified vuln attestation from the last 10 days. If anything is still wrong,
it opens an issue labelled `rebuild-failed`, and closes it once things are
green again.

Maintaining a fork (Cachix setup, first publish, publish checklist): see
[Maintaining a fork](docs/design.md#maintaining-a-fork).

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
          # The identity NVD files this runtime's CVEs under — the scanner's
          # vendor=name guess usually is NOT it, and a wrong one matches
          # nothing, silently. Find it with `grype db search pkg <name>`.
          sbomExtraComponents = [
            (vardeLib.sbomComponent { vendor = "…"; product = "…"; version = p.<pkg>.version; })
          ];
          # stopSignal = "SIGQUIT";    # optional: a daemon whose graceful shutdown isn't SIGTERM
          # sbomStripCpes = [ … ];     # optional: { foundBy?; name; } rules that drop mis-matching CPEs (see images/php.nix)
          # closureAllow = [ … ];      # optional: EREs on full store paths exempted from the closure guard
          # strip = false;             # optional: keep ELF symbol tables (stripped at image assembly by default)
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
`sbomComponent`, `buildImage`, `buildSbomApp`). See [`images/python.nix`](images/python.nix) for a
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
.github/workflows/build.yml     # data-driven matrix build -> grype -> GHCR
.github/workflows/bump-lock.yml # weekly flake.lock bump -> verify on a side branch -> land on main -> dispatch build
.github/workflows/rebuild-watchdog.yml # retry failed rebuilds, flag stale images, track an issue
.github/workflows/e2e.yml       # build + smoke-test the examples
.github/workflows/pages.yml     # deploy the landing page to GitHub Pages
.github/canary/                 # known-CVE SBOM fixture that guards the grype scan
.github/dependabot.yml          # grouped version updates: SHA-pinned actions + example deps
site/                           # landing page (static, no build step)
docs/design.md                  # design notes
docs/debugging.md               # debugging shell-less images (kubectl debug, -debug tags)
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
