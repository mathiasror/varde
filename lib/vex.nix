# OpenVEX document for one image's package set, built at eval time.
#
# grype matches Nix store contents to NVD by CPE and compares upstream
# versions, so a CVE that nixpkgs fixed with a patch, without a version bump,
# keeps showing up. This document records those cases, and the CVEs that do
# apply, so a scan can be honest about both:
#   - automatic `fixed` statements: every CVE id in the name of a patch the
#     package applies (nixpkgs names backports CVE-YYYY-N.patch). They are
#     derived from the derivation itself, so they appear and disappear with
#     the patch;
#   - hand-curated statements from vex/statements.nix: not_affected with a
#     justification, `fixed` behind a `when` guard, or `affected` with an
#     action_statement (the mitigation). An entry's `images` list limits it
#     to those images. `affected` suppresses nothing: grype still reports
#     the match.
#
# Products are package purls exactly as the SBOM spells them: pkg:nix/<pname>@<version>
# (syft's Nix cataloger, and what `grype <image>` sees), plus pkg:generic/<name>@<version>
# for the libc's hand-authored NVD-identity component (lib/default.nix
# sbomComponent). grype matches a VEX product against the match's own package
# purl, and qualifiers missing from the VEX side (outputhash=) are ignored.
#
# vexFor :: { pkgs, image, libc, timestamp, id } -> OpenVEX attrset (toJSON-able)
{ lib }:
let
  # Packages whose patches are mined for CVE ids. A package that an image does
  # not ship is harmless here: its statements simply match nothing.
  watched = [
    "openssl"
    "zlib"
    "krb5"
    "libssh2"
    "libtiff"
    "curl"
    "sqlite"
    "libxml2"
    "expat"
    "xz"
    "busybox-sandbox-shell"
    "ada"
  ];

  cveRe = "(CVE-[0-9]{4}-[0-9]+)";
  cvesIn =
    s: lib.concatMap (x: if lib.isList x then x else [ ]) (builtins.split cveRe (lib.toUpper s));
  patchName = p: if lib.isDerivation p || p ? name then p.name else baseNameOf (toString p);
  patchCves = drv: lib.unique (lib.concatMap (p: cvesIn (patchName p)) (drv.patches or [ ]));

  nixVersion = drv: (builtins.parseDrvName drv.name).version;
  pnameOf = drv: drv.pname or (builtins.parseDrvName drv.name).name;
  nixPurl = drv: "pkg:nix/${pnameOf drv}@${nixVersion drv}";
  # syft's binary cataloger reports some of the same files a second time, as
  # pkg:generic/<name>@<version> (krb5, busybox, postgresql in run
  # 39036176119's SBOMs). A statement must name both, or the second match
  # stays.
  genericPurl = drv: "pkg:generic/${pnameOf drv}@${drv.version or (nixVersion drv)}";
  product = id: { "@id" = id; };

  stmt =
    {
      cve,
      products,
      status,
      justification ? null,
      impact ? null,
      action ? null,
    }:
    {
      vulnerability.name = cve;
      products = map product products;
      inherit status;
    }
    // lib.optionalAttrs (justification != null) { inherit justification; }
    # OpenVEX: impact_statement belongs to not_affected; other statuses get status_notes.
    // lib.optionalAttrs (impact != null) (
      if status == "not_affected" then { impact_statement = impact; } else { status_notes = impact; }
    )
    # OpenVEX requires an action_statement on every `affected` statement.
    // lib.optionalAttrs (action != null) { action_statement = action; };
in
{
  vexFor =
    {
      pkgs,
      image,
      libc,
      timestamp,
      id,
    }:
    let
      p = if libc == "musl" then pkgs.pkgsMusl else pkgs;
      libcDrv =
        if libc == "musl" then
          p.musl
        else if libc == "glibc" then
          p.glibc
        else
          null;
      # pkg:generic/<name>@<version>: same name/version that sbomComponent writes.
      libcPurls = lib.optionals (libcDrv != null) [
        (nixPurl libcDrv)
        "pkg:generic/${libc}@${libcDrv.version}"
      ];
      purlsOf =
        name:
        if name == "libc" then
          libcPurls
        else
          lib.optionals (p ? ${name}) (
            lib.unique [
              (nixPurl p.${name})
              (genericPurl p.${name})
            ]
          );
      drvOf = name: if name == "libc" then libcDrv else p.${name} or null;

      auto = lib.concatMap (
        name:
        let
          drv = drvOf name;
        in
        lib.optionals (drv != null) (
          map (
            cve:
            stmt {
              inherit cve;
              products = purlsOf name;
              status = "fixed";
              impact = "nixpkgs applies a patch for ${cve} to ${drv.name}.";
            }
          ) (patchCves drv)
        )
      ) (watched ++ lib.optional (libcDrv != null) "libc");

      curated = lib.concatMap (
        s:
        lib.optionals
          (
            (s.libc or libc) == libc
            # `images` scopes a statement to some images: the same package
            # purl can be reachable in one image and dead code in another.
            && (s ? images -> lib.elem image s.images)
            && (s.pkg == "libc" -> libcDrv != null)
            && (s.pkg == "libc" || p ? ${s.pkg})
            && (s.when or (_: true)) p
          )
          (
            map (
              cve:
              stmt {
                inherit cve;
                inherit (s) status;
                # `purls` adds products the package attr cannot name, e.g. a
                # hand-authored identity component (pkg:generic/cpython@…).
                products = purlsOf s.pkg ++ (s.purls or (_: [ ])) p;
                justification = s.justification or null;
                impact = s.impact or null;
                action = s.action or null;
              }
            ) s.cves
          )
      ) (import ../vex/statements.nix { inherit lib; });
    in
    {
      "@context" = "https://openvex.dev/ns/v0.2.0";
      "@id" = id;
      author = "varde CI (https://github.com/mathiasror/varde)";
      inherit timestamp;
      version = 1;
      statements = auto ++ curated;
    };
}
