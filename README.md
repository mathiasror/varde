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
Each alias carries copies of its source's per-arch signature, SBOM and
provenance attestations (the same Rekor entries), so the verification recipe
below works against the alias name too.

Each is published to **GHCR** under `ghcr.io/mathiasror/<image>`, multi-arch
(`amd64` + `arm64`).

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
`:21-musl-arm64` or `:3.13-glibc-amd64`.

*`varde-jre:17` is **glibc-only** — Adoptium ships no aarch64 Alpine/musl JRE for
JDK 17; `:21` and `:25` default to musl. `varde-mysql` is **glibc-only** — musl
MySQL is not buildable from nixpkgs (its protobuf/abseil pin is marked broken
on musl), so its bare tags are the glibc build. `varde-static` carries no libc
(static binaries embed their own), so it has no `-musl`/`-glibc` split.

`varde-postgres` is the **one exception to "no shell"**: it ships a minimal
static `ash` at `/bin/sh` (Nix's own busybox-sandbox-shell — a single binary,
no other applets) because PostgreSQL's `initdb` bootstraps through libc
`popen`/`system`, which hardcode `/bin/sh`. Every other image remains
shell-free.

### Every image guarantees

| Property | Value |
| --- | --- |
| User | `1000:1000` (`app`, non-root) |
| Working directory | `/app` (owned by `1000:1000`) |
| Shell / package manager | **none** |
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
sole, explicit exemption, pinned to that exact derivation. The guard is only
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

The shortest possible case (a static binary):

```dockerfile
# a.k.a. varde-go
FROM ghcr.io/mathiasror/varde-static:latest
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
# or push to your own namespace without a daemon:
skopeo copy docker-archive:result docker://ghcr.io/YOUR_USER/varde-jre:21-musl-amd64
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
silently. The VEX is explained in the next section.

The attestations live on the **per-arch digests** (the things actually built),
not on the multi-arch tag, so resolve a platform digest first. Images are
reproducible, so a digest that did not change between weekly runs collects
one attestation of each type per run; the `jq -s … max_by` keeps the newest:

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

Or generate the SBOM from the flake on Linux (fetches the image tarball from
the cache, or builds it, and reads it):

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

### False positives and the OpenVEX attestation

grype compares upstream versions, so a CVE that nixpkgs fixed with a patch,
without bumping the version, still shows up, and so do CVEs filed against a
different product or a component that varde does not ship. Each image carries
an **OpenVEX attestation** that records those cases. It holds a `fixed`
statement for every CVE a nixpkgs patch in the image is named after, plus the
hand-reviewed `not_affected` and `fixed` statements in
[`vex/statements.nix`](vex/statements.nix), each with its evidence. It is
generated from the same commit as the image ([`lib/vex.nix`](lib/vex.nix)),
and CI's scan applies it. To apply it yourself, extract it as in
[the CI-equivalent scan](#the-ci-equivalent-scan-attested-sbom--vex), then:

```bash
grype --vex vex.openvex.json sbom:sbom.cdx.json   # or: grype --vex vex.openvex.json "$IMG@$d"
```

grype moves VEX-covered matches to `ignoredMatches` (see `-o json`) rather than
deleting them, so you can always audit what was suppressed and why. From a
checkout, `nix eval --json .#vex.x86_64-linux.sbom-postgres-17-glibc` prints the same
document. A statement is varde's claim, not upstream's, so review
`vex/statements.nix` if your policy requires it.

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

The one signing identity is `build.yml` **on `main`** — publishing is refused
from any other ref — so verify against that exact identity rather than a
repo-wide pattern (which would also accept other workflows and branches):

```bash
# Verify a signature (the identity is this repo's build.yml workflow on main):
cosign verify \
  --certificate-identity https://github.com/mathiasror/varde/.github/workflows/build.yml@refs/heads/main \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/mathiasror/varde-jre:21

# Provenance, SBOM, VEX and vuln-scan attestations live on the per-arch
# digests (the things actually built) — resolve a platform digest first:
d=$(crane digest ghcr.io/mathiasror/varde-jre:21 --platform linux/amd64)

# Verify SLSA build provenance (same exact identity; --bundle-from-oci reads
# the attestation attached to the image in GHCR, the copy CI gates on, rather
# than the GitHub attestations API):
gh attestation verify "oci://ghcr.io/mathiasror/varde-jre@${d}" \
  --repo mathiasror/varde \
  --cert-identity https://github.com/mathiasror/varde/.github/workflows/build.yml@refs/heads/main \
  --bundle-from-oci

# Verify the CycloneDX SBOM attestation and extract the SBOM (a digest that
# survived several weekly runs carries one per run; keep the newest):
cosign verify-attestation --type cyclonedx \
  --certificate-identity https://github.com/mathiasror/varde/.github/workflows/build.yml@refs/heads/main \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  "ghcr.io/mathiasror/varde-jre@${d}" \
  | jq -s '[.[].payload | @base64d | fromjson | .predicate] | max_by(.metadata.timestamp)' > sbom.cdx.json
```

The same `cosign verify-attestation` with `--type openvex` or `--type vuln`
verifies the other two; [Scanning varde images](#scanning-varde-images) shows
how to extract and use them.

## CI

[`.github/workflows/build.yml`](.github/workflows/build.yml) is fully
data-driven from the flake:

1. **setup** — reads `.#ciMatrix`, `.#latestTags`, and `.#imageAliases`, crosses
   every image/variant (including libc) with `amd64` + `arm64`.
2. **build** — native runners (`ubuntu-latest` / `ubuntu-24.04-arm`): build the
   image, generate the SBOM, grype-scan it (behind a known-CVE canary),
   Trivy-scan the image filesystem for secrets, smoke-test it, push it to GHCR by digest,
   sign + attest + verify it, and only then move the per-arch tag onto that
   digest (all skipped on PRs).
3. **manifest** — assembles multi-arch lists per libc tag, the bare-version and
   `:latest` / `:latest-glibc` aliases, and the `varde-go` / `varde-rust` alias
   digests — from this run's verified per-arch digests, per image:tag pair. A
   leg that failed or timed out holds back only the lists that need it (the
   job names them and goes red); every other pair is still refreshed.

Publishing happens from `main` only: `push` is filtered to `main` and a
`workflow_dispatch` from any other ref fails in `setup`.

[`.github/workflows/e2e.yml`](.github/workflows/e2e.yml) builds every example on
top of a locally-built base, smoke-tests that the app runs, and asserts an
image-size budget ([`scripts/e2e.sh`](scripts/e2e.sh)) — on PRs that touch an
input, and on `main` after every successful `build-image` run (each weekly
bump, and every merge that rebuilds the images — an examples-only merge is
covered by its PR-time run), warm from the Cachix cache that build just
populated.

Both `build` and `e2e` push/pull a shared **Cachix** cache so the from-source
musl variants are compiled once and reused across jobs, later runs, and the e2e
workflow (the first run is slow; subsequent ones are downloads).

Auth uses the built-in `GITHUB_TOKEN`. A weekly job
([`bump-lock.yml`](.github/workflows/bump-lock.yml)) bumps `flake.lock` to the
latest nixpkgs, commits the bump to `main` (a GitHub-signed bot commit), and
dispatches the build from that commit — so published images pick up CVE fixes
*and* every published image corresponds to a commit of this repo whose lock
reproduces it.

> **Cache setup, one-time:** create a free open-source cache named `varde` at
> [cachix.org](https://cachix.org) (keep it **public** so fork PRs and end users
> can read it), then add its write token as the repo secret `CACHIX_AUTH_TOKEN`
> (Settings → Secrets and variables → Actions). Reads are anonymous on a public
> cache — the token is only needed to *push*; without it builds still work and
> still pull the cache, they just can't refill it.

> **First publish, one-time step** *(done for `ghcr.io/mathiasror` — this
> applies if you fork and publish your own)*: packages pushed by Actions are created
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
.github/workflows/bump-lock.yml # weekly flake.lock bump -> commit to main -> dispatch build
.github/workflows/e2e.yml       # build + smoke-test the examples
.github/workflows/pages.yml     # deploy the landing page to GitHub Pages
.github/canary/                 # known-CVE SBOM fixture that guards the grype scan
.github/dependabot.yml          # grouped version updates: SHA-pinned actions + example deps
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
