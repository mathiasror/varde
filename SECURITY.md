# Security Policy

## Reporting a vulnerability

Please report security issues **privately** rather than opening a public issue.

Use GitHub's private vulnerability reporting: go to the repository's
**Security → Report a vulnerability** tab
(<https://github.com/mathiasror/varde/security/advisories/new>). This opens a
private advisory visible only to the maintainers.

Please include the affected image and tag (e.g. `varde-python:3.14`), the
architecture, and enough detail to reproduce. We aim to acknowledge reports
within a few days.

## Scope

varde packages upstream runtimes and system libraries (the Temurin JRE, CPython,
Node.js, glibc, and so on) using Nix. Two different kinds of findings:

- **A vulnerability in varde's own build** — the flake, the image modules, the
  shared library, or the workflows (for example, a misconfiguration that ships a
  shell, runs as root, or leaks a credential). Report these here.
- **A CVE in a packaged upstream component** — these flow in automatically. A
  weekly job commits a `flake.lock` bump to the `bump/flake-lock` side branch,
  builds the full matrix and the examples from it without publishing, and only
  if both are green fast-forwards `main` to that exact commit and publishes
  from it. Upstream fixes land without manual work and every published image
  is traceable to a commit that reproduces it. A build that fails during
  verification holds back the whole week's refresh: `main` and the images stay
  on last week's lock. After landing, a publish leg that fails holds back only
  that image:tag's manifest lists, and the run goes red naming them. A
  watchdog retries failed runs and opens a `rebuild-failed` issue when a
  rebuild stays red or an image goes stale. Known-affected CVEs and their
  mitigations are published as `affected` statements in each image's OpenVEX
  attestation. Scan any image yourself with
  `grype <image>`, or grype its attested CycloneDX SBOM with its OpenVEX
  applied, or read CI's attested scan result (see **Scanning varde images** in
  the README). Trivy, Docker Scout and Snyk cannot see Nix packages and report
  these images clean — don't rely on them. A fix ultimately
  belongs upstream/in nixpkgs; you're still welcome to flag one here if an
  image is lagging.

## Verifying what you pulled

Published images are keyless-signed with cosign (Sigstore, via GitHub Actions
OIDC) and carry CycloneDX SBOM, OpenVEX, vulnerability-scan (a point-in-time
grype result) and SLSA build-provenance attestations. The only identity that
signs is
`https://github.com/mathiasror/varde/.github/workflows/build.yml@refs/heads/main`
— publishing is refused from any other ref — and a per-arch tag is moved onto
a digest only after its signature and attestations are attached and verified.
Before trusting an image you can verify the signature, provenance, and SBOM
against that exact identity — see **Supply chain: signatures, SBOM &
provenance** in the README for the `cosign verify` / `gh attestation verify` /
`cosign verify-attestation` commands.

## Supported versions

Only the tags currently published from `main` are maintained (see the image
table in the README). End-of-life runtime lines are not published — for example
Node.js 20 is intentionally excluded because it is EOL and nixpkgs marks it
insecure.
