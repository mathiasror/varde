# Distrust regression fixtures

Public certificates for the CA-distrust checks in `lib/default.nix`
(`mkCacert`, `checkDistrust`). The image build verifies each chain twice:

- against **its own root alone**: it must verify. That shows the fixture is a
  valid chain and that the check can see it.
- against **varde's CA bundle**: it must be **rejected**, or the build fails.

Both runs use `openssl verify -purpose sslserver -no_check_time`, so expiry
can never make the check pass on its own.

## eMudhra intermediate key compromise (October 2026)

The private keys of eight eMudhra intermediates were recoverable from their
certificates (<https://emudhra.we-have-a-problem.com/>, Mozilla
[bug 2083449](https://bugzilla.mozilla.org/show_bug.cgi?id=2083449)). Each key
exists twice: under `emSign ECC Root CA - G3` and cross-signed by Sectigo's
`AAA Certificate Services` (`Comodo AAA Services root` in NSS).

The leaf and intermediates are the chains that the incident's own test hosts
serve, fetched 2026-10-21:

| File | Subject | Issuer |
|---|---|---|
| `emsign-leaf.pem` | `dv-g3b-emudhra.we-have-a-problem.com` | `EM DV TLS CA - G3B` |
| `emsign-intermediates.pem` | `EM DV TLS CA - G3B` (compromised), `emSign Root TLS CA - G3` | `emSign ECC Root CA - G3` |
| `emsign-ecc-root-ca-g3.pem` | `emSign ECC Root CA - G3`, SHA-256 `86:A1:EC:BA:…:6B:BE:6B` | self |
| `aaa-leaf.pem` | `dv-g3b-aaa-emudhra.we-have-a-problem.com` | `EM DV TLS CA - G3B` |
| `aaa-intermediates.pem` | `EM DV TLS CA - G3B` (compromised, Sectigo cross-sign) | `AAA Certificate Services` |
| `aaa-certificate-services.pem` | `AAA Certificate Services`, SHA-256 `D7:A7:A0:FB:…:69:9E:F4` | self |

The two roots were taken from nixpkgs' `cacert` 3.126.
