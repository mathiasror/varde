# Hand-curated OpenVEX statements: scanner matches that are not real for a
# varde image. lib/vex.nix also emits `fixed` statements automatically for
# every CVE that a nixpkgs patch is named after (CVE-*.patch), so list here
# only what that cannot see:
#   - wrong product or version-range noise, where nothing is patched;
#   - a vulnerable component that varde does not ship (KDC, nscd, an applet);
#   - fixes that arrive under an unchanged version string (glibc's 2.44-N
#     branch level), guarded by `when` so the statement exists only for a
#     build that really carries the fix.
#
# Every entry must cite evidence. `when` gets the libc package set and must be
# true for the statement to be emitted; leave it out for unconditional facts.
# `images` (image names, e.g. [ "php" ]) limits an entry to those images, for
# a package that is reachable in some images and not others. An `affected`
# entry needs an `action` (OpenVEX action_statement) telling users what to do.
# `pkg` is an attribute of that package set, or "libc" for glibc/musl.
# Statuses/justifications: https://github.com/openvex/spec/blob/main/OPENVEX-SPEC.md
{ lib }:
let
  # nixpkgs glibc's store name carries the release/2.44/master commit level
  # ("glibc-2.44-25"), while `.version` is "2.44".
  glibcLevelAtLeast = lvl: p: lib.versionAtLeast (builtins.parseDrvName p.glibc.name).version lvl;
in
[
  # --- glibc ---------------------------------------------------------------
  {
    pkg = "libc";
    libc = "glibc";
    cves = [ "CVE-2026-0861" ];
    status = "not_affected";
    justification = "vulnerable_code_not_present";
    impact = "Fixed upstream in glibc 2.43 (GLIBC-SA-2026-0001, c9188d33); 2.44 contains the fix. NVD's range is stale.";
  }
  {
    pkg = "libc";
    libc = "glibc";
    cves = [
      "CVE-2010-4756"
      "CVE-2019-1010022"
      "CVE-2019-1010023"
      "CVE-2019-1010024"
      "CVE-2019-1010025"
    ];
    status = "not_affected";
    justification = "vulnerable_code_cannot_be_controlled_by_adversary";
    impact = "Disputed and rejected by glibc upstream as not security bugs (glob resource use / ASLR and stack-guard bypasses that need a separate memory-corruption bug). No fix exists or is planned.";
  }
  {
    pkg = "libc";
    libc = "glibc";
    cves = [ "CVE-2026-97399" ];
    status = "not_affected";
    justification = "vulnerable_code_not_present";
    impact = "POWER8-only strncasecmp; varde builds x86_64 and aarch64 only (GLIBC-SA-2026-0024).";
  }
  {
    pkg = "libc";
    libc = "glibc";
    cves = [ "CVE-2026-89092" ];
    status = "not_affected";
    justification = "component_not_present";
    impact = "nscd is not shipped: images carry only glibc's lib output (GLIBC-SA-2026-0016).";
  }
  # Fixed on release/2.44/master; nixpkgs carries them in 2.44-master.patch
  # from glibc 2.44-57 (nixpkgs bad5c9c6, da11d653; on master 2026-10-16).
  {
    pkg = "libc";
    libc = "glibc";
    cves = [
      "CVE-2026-18374"
      "CVE-2026-19499"
      "CVE-2026-19542"
      "CVE-2026-77117"
      "CVE-2026-80489"
      "CVE-2026-8674"
      "CVE-2026-86805"
      "CVE-2026-95818"
    ];
    status = "fixed";
    impact = "Backported via nixpkgs glibc 2.44-master.patch (release/2.44/master at 2.44-57).";
    when = glibcLevelAtLeast "2.44-57";
  }

  # --- krb5 ----------------------------------------------------------------
  {
    pkg = "krb5";
    cves = [
      "CVE-2007-3149"
      "CVE-2007-5894"
    ];
    status = "not_affected";
    justification = "component_not_present";
    impact = "CVE-2007-3149 is a sudo bug; CVE-2007-5894 is gssftp ftpd, removed from krb5 long ago. Only krb5's lib output ships.";
  }
  {
    pkg = "krb5";
    cves = [ "CVE-2026-107708" ];
    status = "not_affected";
    justification = "component_not_present";
    impact = "krb5kdc (src/kdc) is not shipped; images carry only krb5's lib output.";
  }
  # krb5_rd_cred NULL dereference (ticket 9211; master 48afa9ab, krb5-1.22
  # branch 62196e2b, unreleased as of 2026-10-22). Reached only through the
  # GSS-API acceptor (gss_accept_sec_context), so it depends on the image.
  {
    pkg = "krb5";
    images = [
      "php"
      "mysql"
    ];
    cves = [ "CVE-2026-107778" ];
    status = "not_affected";
    justification = "vulnerable_code_not_in_execute_path";
    impact = "krb5_rd_cred is reached only from the GSS-API acceptor (gss_accept_sec_context). These images use krb5 only as an initiator (libcurl SPNEGO, libpq, c-client); mysqld runs no ONC-RPC server (libtirpc svc_auth_gss), and the server-side Kerberos auth plugin is MySQL Enterprise only.";
    when = p: !(lib.versionAtLeast p.krb5.version "1.22.3");
  }
  {
    pkg = "krb5";
    images = [ "postgres" ];
    cves = [ "CVE-2026-107778" ];
    status = "affected";
    impact = "postgres is built --with-gssapi and calls gss_accept_sec_context for a GSSENCRequest on any TCP connection, before pg_hba is consulted. Unreachable without a keytab (the image ships none); reachable by any client holding a service ticket once one is configured.";
    action = "If you do not use Kerberos, do not provide a keytab (krb_server_keyfile, KRB5_KTNAME or /etc/krb5.keytab): the acceptor then fails before the vulnerable code. If you do, restrict network access to trusted clients until varde ships krb5 1.22.3 or a backport of krb5 62196e2b. gss_accept_delegation = off does not mitigate this.";
    when = p: !(lib.versionAtLeast p.krb5.version "1.22.3");
  }
  {
    pkg = "krb5";
    cves = [ "CVE-2026-107778" ];
    status = "fixed";
    impact = "Fixed in krb5 1.22.3 (62196e2b, ticket 9211); NVD carries no fix bound, so 1.22.3 still matches.";
    when = p: lib.versionAtLeast p.krb5.version "1.22.3";
  }

  # --- libtiff -------------------------------------------------------------
  {
    pkg = "libtiff";
    cves = [ "CVE-2026-4775" ];
    status = "not_affected";
    justification = "vulnerable_code_not_present";
    impact = "Fixed by libtiff 782a11d6, released in v4.7.2. NVD's CPE has no version bound.";
    when = p: lib.versionAtLeast p.libtiff.version "4.7.2";
  }

  # --- busybox (busybox-sandbox-shell, postgres /bin/sh) ---------------------
  {
    pkg = "busybox-sandbox-shell";
    cves = [
      "CVE-2024-58251"
      "CVE-2025-46394"
    ];
    status = "not_affected";
    justification = "vulnerable_code_not_present";
    impact = "busybox-sandbox-shell is enableMinimal (allnoconfig) + ash; the netstat and tar applets are not compiled in.";
  }

  # --- ada (node) ----------------------------------------------------------
  {
    pkg = "ada";
    cves = [ "CVE-2024-9410" ];
    status = "not_affected";
    justification = "component_not_present";
    impact = "Different product: an SSRF in the Ada.cx SaaS's Sentry config, not the ada-url C++ URL parser.";
  }

  # --- redis ---------------------------------------------------------------
  {
    pkg = "redis";
    cves = [ "CVE-2022-0543" ];
    status = "not_affected";
    justification = "vulnerable_code_not_present";
    impact = "Debian/Ubuntu packaging bug: their redis linked the system Lua dynamically and exposed `package`, allowing a Lua sandbox escape. Upstream redis (and nixpkgs) uses its bundled, statically linked Lua.";
  }
  {
    pkg = "redis";
    cves = [ "CVE-2022-3734" ];
    status = "not_affected";
    justification = "component_not_present";
    impact = "Affects the unofficial Windows port's dbghelp.dll search path; varde ships Linux builds only.";
  }
  {
    pkg = "redis";
    cves = [ "CVE-2025-49112" ];
    status = "not_affected";
    justification = "vulnerable_code_not_present";
    impact = "setDeferredReply integer underflow, fixed in redis 8.0.3 (and Valkey 8.1.4); NVD's redis CPE carries no version bound.";
    when = p: lib.versionAtLeast p.redis.version "8.0.3";
  }

  # --- postgresql ------------------------------------------------------------
  {
    pkg = "postgresql";
    purls =
      p:
      lib.concatMap
        (a: [
          "pkg:nix/postgresql@${p.${a}.version}"
          "pkg:generic/postgresql@${p.${a}.version}"
        ])
        [
          "postgresql_16"
          "postgresql_17"
          "postgresql_18"
        ];
    cves = [ "CVE-2017-8806" ];
    status = "not_affected";
    justification = "component_not_present";
    impact = "Debian's postgresql-common pg_ctlcluster/pg_createcluster scripts (symlink attack on log files); not part of PostgreSQL and not shipped. NVD's CPE is versionless.";
  }

  # --- python ----------------------------------------------------------------
  {
    pkg = "python3";
    purls =
      p:
      lib.concatMap
        (a: [
          "pkg:nix/python3@${p.${a}.version}"
          "pkg:generic/cpython@${p.${a}.version}"
        ])
        [
          "python311"
          "python312"
          "python313"
        ];
    cves = [ "CVE-2024-3220" ];
    status = "not_affected";
    justification = "vulnerable_code_not_present";
    impact = "mimetypes reads writable registry/default paths on Windows only; varde ships Linux builds.";
  }
  {
    pkg = "python3";
    purls =
      p:
      lib.concatMap
        (a: [
          "pkg:nix/python3@${p.${a}.version}"
          "pkg:generic/cpython@${p.${a}.version}"
        ])
        [
          "python311"
          "python312"
          "python313"
        ];
    cves = [ "CVE-2026-3479" ];
    status = "not_affected";
    justification = "vulnerable_code_cannot_be_controlled_by_adversary";
    impact = "Disputed (NVD). pkgutil.get_data() has the same security model as open(): upstream reverted the resource-name check (gh-146121, PR #148197) and documented that instead; the 3.11/3.12 backports (#146136, #146135) were closed unmerged. No code fix exists or is planned.";
  }
]
