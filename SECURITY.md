# Security Policy

## Reporting a vulnerability

Please report security issues **privately** rather than opening a public issue.

Use GitHub's private vulnerability reporting: go to the repository's
**Security → Report a vulnerability** tab
(<https://github.com/mathiasror/varde/security/advisories/new>). This opens a
private advisory visible only to the maintainers.

Please include the affected image and tag (e.g. `varde-python:3.13`), the
architecture, and enough detail to reproduce. We aim to acknowledge reports
within a few days.

## Scope

varde packages upstream runtimes and system libraries (the Temurin JRE, CPython,
Node.js, glibc, and so on) using Nix. Two different kinds of findings:

- **A vulnerability in varde's own build** — the flake, the image modules, the
  shared library, or the workflows (for example, a misconfiguration that ships a
  shell, runs as root, or leaks a credential). Report these here.
- **A CVE in a packaged upstream component** — these flow in automatically. The
  images are rebuilt weekly against the latest nixpkgs, so upstream fixes land
  without any change to this repo, and every image ships a CycloneDX SBOM you can
  scan yourself with grype (see the README). A fix ultimately belongs upstream/in nixpkgs;
  you're still welcome to flag one here if an image is lagging.

## Verifying what you pulled

Published images are keyless-signed with cosign (Sigstore, via GitHub Actions
OIDC) and carry a CycloneDX SBOM attestation and a SLSA build-provenance
attestation. Before trusting an image you can verify the signature, provenance,
and SBOM — see **Supply chain: signatures, SBOM & provenance** in the README for
the exact `cosign verify` / `gh attestation verify` / `cosign verify-attestation`
commands.

## Supported versions

Only the tags currently published from `main` are maintained (see the image
table in the README). End-of-life runtime lines are not published — for example
Node.js 20 is intentionally excluded because it is EOL and nixpkgs marks it
insecure.
