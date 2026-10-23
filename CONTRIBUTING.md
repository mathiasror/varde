# Contributing to varde

Thanks for helping. varde is maintained by one person, so small, focused PRs
that keep the image contract intact are the ones that land quickly.

**Security issues do not go in public issues or PRs.** Report them privately
as described in [SECURITY.md](SECURITY.md). A CVE in a packaged upstream
component (openssl, glibc, a runtime) is not a varde vulnerability; if an
image is lagging a fix, open a "CVE lagging" issue (see
[Triage of CVEs and VEX](#triage-of-cves-and-vex)).

## Building and testing locally

You need Nix with flakes enabled. Images are Linux-only: the flake defines
packages for `x86_64-linux` and `aarch64-linux` only.

On a Linux host:

```bash
nix build .#image-redis-latest-musl          # -> ./result, a Docker-format image tarball
nix build .#image-python-3_13-glibc          # dots in the tag become underscores
docker load < result
nix run .#sbom-redis-latest-musl -- sbom.cdx.json   # the SBOM CI attests
grype sbom:sbom.cdx.json
```

On macOS you need a Linux builder (nixpkgs'
[`darwin.linux-builder`](https://nixos.org/manual/nixpkgs/stable/#sec-darwin-builder)
or nix-darwin's `nix.linux-builder`), and you have to name the Linux system,
because `.#image-…` does not exist for `aarch64-darwin`:

```bash
nix build .#packages.aarch64-linux.image-redis-latest-musl
```

Running the image, the SBOM app and `scripts/e2e.sh` need Linux and Docker.
Without a Linux builder, evaluate on macOS and let CI do the build: a PR builds
and smoke-tests every image it touches on both arches.

Useful commands that work on any host:

```bash
nix flake show --all-systems          # every image-<name>-<tag> package and sbom-* app
nix eval --json .#ciMatrix            # what CI builds: [{image, tag, attr, sbomName, libc}, …]
nix eval --json .#latestTags          # which tag each image publishes as :latest
nix eval --json .#vex.x86_64-linux.sbom-redis-latest-musl   # an image's OpenVEX document
```

`scripts/e2e.sh [example…]` builds the musl bases, builds every example under
`examples/` on top, smoke-tests it and checks its size budget (Linux, Docker
and Nix). Musl builds are not in `cache.nixos.org`; `cachix use varde` pulls
them from the project cache instead of compiling from source.

## Adding an image or a tag

Follow [Adding a new image](README.md#adding-a-new-image) in the README and the
existing modules (`images/python.nix` for a runtime with versions,
`images/redis.nix` or `images/nginx.nix` for a service, `images/glibc.nix` for
a compiled-binary base). In short:

- **A new tag** for an existing image is one more entry under `versions` in
  `images/<name>.nix`, for example `"3.14" = { spec = p: pySpec p p.python314; };`.
  Move `latest` only when the new line is the upstream default. End-of-life
  runtime lines are not added (nixpkgs usually marks them insecure anyway).
- **A new image** is a new `images/<name>.nix`. The flake discovers it, so CI
  needs no workflow changes for the build itself. Use `vardeLib.mkVariants`
  so it is built for both libcs; restrict `libcs` only when one is not
  buildable, and say why in a comment.
- Add `sbomExtraComponents` with the NVD vendor and product of the runtime
  (find them with `grype db search pkg <name>`). Without them the scanner
  silently matches nothing.
- Add a smoke-test case for the image in the "Smoke test" step of
  `.github/workflows/build.yml`. An image without one only prints
  "no smoke test defined".
- Add an example under `examples/<image>/simple/` with an `ARG BASE_IMAGE`,
  and a row in the table in `scripts/e2e.sh`.
- Update the image lists in `README.md` and `site/index.html`.

Explain the non-obvious in comments next to the code, the way the existing
modules do (why a dependency is dropped, why a check is skipped, with the CI
run or upstream issue that proves it). A reviewer has to be able to tell a
deliberate exception from an accident.

## Rules that must not break

These are the image contract. A PR that breaks one will not be merged.

- **No shell.** Nothing in an image's runtime closure may be a shell, coreutils,
  busybox and the like. The closure guard in [`lib/default.nix`](lib/default.nix)
  (`closureDenyPatterns`, `closureGuard`) fails the build if one appears. Fix
  the dependency that pulled it in (see how `images/redis.nix` drops
  jemalloc's bash scripts); do not add to `closureAllow` to make the build
  pass. Postgres's static `/bin/sh` is the single, disclosed exemption.
- **No package manager.** No `npm`, `pip`, `composer` or similar at runtime.
  Users install dependencies in a builder stage.
- **Non-root.** Every image runs as `1000:1000` (`app`) with `WORKDIR /app`.
  Do not change the user or add setuid binaries.
- **No `-dev` outputs** in the closure. The closure guard checks this too.
- **musl is the default libc**, glibc is opt-in with `-glibc`.
- **Reproducible and traceable.** Everything comes from the pinned
  `flake.lock`. No network fetches outside Nix, no binaries downloaded at build
  time without a fixed hash.
- **No faked package metadata.** varde does not add distro package URLs or
  similar to make other scanners report findings.

## Triage of CVEs and VEX

The weekly `flake.lock` bump brings upstream fixes in. Most CVE work is
deciding whether a scanner finding is real.

- **Use grype.** Trivy, Docker Scout and Snyk cannot see Nix packages and
  report 0 findings on these images, which tells you nothing. Scan with
  `grype <image>`, or with the attested SBOM and VEX as the README describes.
- **Fixed by a nixpkgs patch?** If nixpkgs applies a patch named
  `CVE-YYYY-N.patch` to a package in the `watched` list in
  [`lib/vex.nix`](lib/vex.nix), a `fixed` statement is generated
  automatically. Extend the list if a package is missing.
- **Otherwise add a statement** to [`vex/statements.nix`](vex/statements.nix):
  `not_affected` with an OpenVEX justification, `fixed` with a `when` guard
  that is true only for builds that carry the fix, or `affected` with an
  `action` that tells users how to mitigate. Use `images` when the CVE is
  reachable in some images and not in others. Every entry must cite evidence:
  an upstream advisory, a commit, or the code path. "Probably not reachable"
  is not evidence.
- **A real fix that the channel does not have yet** belongs upstream in
  nixpkgs. A temporary overlay in `flake.nix` is acceptable for a serious CVE.
  Follow the existing ones: guard it on the old version so it becomes a no-op
  once nixpkgs catches up, and keep it musl-only unless glibc really needs
  it, so glibc images keep coming from `cache.nixos.org`.

Check the result with `nix eval --json .#vex.<system>.<sbomName>` and
`grype --vex vex.openvex.json sbom:sbom.cdx.json`.

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org/):
`type(scope): summary`, in the imperative and lower case, for example
`fix(redis): drop jemalloc's bash scripts from the closure` or
`feat(images): add memcached`. Types used here: `feat`, `fix`, `docs`, `ci`,
`refactor`, `test`, `chore`. The scope is usually the image name or `ci`,
`vex`, `sbom`, `nix`, `site`, `musl`. Use the body to say why, and link the
CI run or upstream issue when there is one.

## Pull requests

1. Fork, branch from `main`, and keep the PR to one change.
2. Fill in the PR template. Say which images and tags are affected and how you
   tested (a local build, the PR's CI run, `scripts/e2e.sh`).
3. CI builds and smoke-tests the images your diff touches on amd64 and arm64
   (changes to `lib/`, `flake.nix` or `flake.lock` rebuild everything), and
   e2e runs the examples. Musl builds that miss the cache compile from
   source and can take a long time.
4. Nothing is published from a PR. Images are signed and pushed only from
   `main` after merge.
5. Leave `flake.lock` alone unless the PR is about it: a weekly workflow bumps
   nixpkgs and verifies the bump before it lands.

By contributing you agree that your contribution is licensed under the
[Apache License 2.0](LICENSE), like the rest of the project. This project
follows a [Code of Conduct](CODE_OF_CONDUCT.md).
