# Minimal distroless JRE for JVM apps (Java/Kotlin).
#
# Ships a prebuilt headless Temurin JRE — a real runtime (no compiler, jshell, or
# other dev/diagnostic tooling, unlike a full JDK or an ALL-MODULE-PATH jlink
# image), relocated under /runtime. For an even smaller, app-specific runtime,
# jlink your app's own modules (`jdeps --print-module-deps`) in your build and
# drop the result onto a scratch/glibc varde base instead — that's where jlink
# actually pays off.
#
# Contract: drop a self-contained executable JAR at /app/app.jar. No shell, so
# Gradle `application` start scripts won't run — bring a fat/uber jar.
#
# Built for both libcs where a Temurin build exists: the bare tag (e.g. :21) is
# musl (Temurin's Alpine build), opt into glibc with :21-glibc. NOTE: :17 is
# glibc-only — Adoptium ships no aarch64 Alpine/musl JRE for JDK 17.
{
  pkgs,
  vardeLib,
  lib,
}:
let
  # `p` is the libc's package set (pkgs for glibc, pkgs.pkgsMusl for musl); the
  # musl set resolves temurin-jre-bin-* to Temurin's Alpine/musl prebuilt.
  jreSpec = p: jre: {
    contents = [
      (p.runCommand "varde-jre-root-${jre.version}" { } ''
        mkdir -p "$out"
        # Resolve the real JRE home (handles flat or nested nixpkgs layouts) so
        # /runtime is a self-contained Java home with java at /runtime/bin/java.
        # Symlink, don't copy: the closure ships the store path either way, and
        # a copy would double the JRE payload in the image (see lib relocate).
        home="$(dirname "$(dirname "$(readlink -f ${jre}/bin/java)")")"
        ln -s "$home" "$out/runtime"
      '')
    ];
    entrypoint = [ "/runtime/bin/java" ];
    cmd = [
      "-jar"
      "/app/app.jar"
    ];
    env = [
      "JAVA_HOME=/runtime"
      "PATH=/runtime/bin"
    ];

    # SBOM: Temurin has essentially no NVD identity of its own — JDK CVEs are
    # filed against the upstream codebase as `oracle:openjdk` (whose CPE
    # versions use the same 21.0.x update scheme) — so the vendor=name CPE
    # syft derives (temurin-jre-bin:…) matches nothing. Scan metadata only.
    #
    # Version: nixpkgs' temurin `version` is the 3-part feature/update triple
    # (25.0.4) even when Adoptium ships a 4-part respin (jdk-25.0.4.1+1), and
    # NVD's Oracle CPU ranges are cut at the respin (`< 25.0.4.1`) — so
    # jre.version reported CVEs the shipped JRE already fixes. Take the
    # release from the Adoptium download URL instead (…/download/jdk-25.0.4.1%2B1/…),
    # falling back to jre.version if the layout ever changes.
    sbomExtraComponents = [
      (vardeLib.sbomComponent {
        vendor = "oracle";
        product = "openjdk";
        version =
          let
            m = builtins.match ".*/download/jdk-([0-9.]+)%2B[0-9]+/.*" (builtins.head jre.srcs).url;
          in
          if m == null then jre.version else builtins.head m;
      })
    ];
  };
in
{
  description = "Minimal distroless Temurin JRE for JVM apps";
  latest = "21"; # current default LTS
  variants = vardeLib.mkVariants pkgs {
    versions =
      let
        # gtkSupport wraps java with a desktop LD_LIBRARY_PATH — GTK+3, glib,
        # cairo and their icu/cups/iso-codes tail, ~240MB of closure a headless
        # container never dlopens (and hours of from-source GTK builds on musl).
        #
        # Even with GTK off, temurin wraps EVERY executable in a *shell*
        # wrapper (bin/java is a bash script exec'ing bin/.java-wrapped) whose
        # sole remaining payload is cups on LD_LIBRARY_PATH — putting bash in
        # every JRE image, executing it on every container start, and
        # dragging cups' avahi/gnutls closure (which itself reaches bash)
        # along. A headless container doesn't print: drop the wrappers
        # entirely and ship the raw ELFs — the same reasoning as gtkSupport
        # above. Java's CUPS print service simply fails cleanly if ever
        # asked. Cheap: temurin-bin is a prebuilt tarball, so this only
        # re-runs its install phase, not a JDK build.
        #
        # Sound goes the same way: lib/libjsound.so (javax.sound) is the only
        # consumer of alsa-lib, whose UCM config (alsa-ucm-conf) hard-codes
        # coreutils' rm/mkdir — so it put coreutils in every JRE image, which
        # lib/default.nix's closure guard rejects. Delete the library and its
        # alsa-lib input; javax.sound fails cleanly if ever asked. preFixup,
        # not postInstall: temurin's installPhase never runs that hook, and
        # this must happen before autoPatchelf (a postFixup hook) looks for
        # libasound.
        jre =
          p: attr:
          jreSpec p (
            (p.${attr}.override { gtkSupport = false; }).overrideAttrs (prev: {
              buildInputs = lib.filter (d: lib.getName d != "alsa-lib") prev.buildInputs;
              preFixup = ''
                find "$out" -name 'libjsound.so' -delete
              ''
              + (prev.preFixup or "");
              postFixup = (prev.postFixup or "") + ''
                find "$out" -name '.*-wrapped' -type f | while IFS= read -r w; do
                  b="$(dirname "$w")/$(basename "$w" | sed 's/^\.//; s/-wrapped$//')"
                  mv "$w" "$b"
                done
              '';
            })
          );
      in
      {
        # No aarch64 Alpine/musl Temurin for 17 -> glibc-only.
        "17" = {
          spec = p: jre p "temurin-jre-bin-17";
          libcs = [ "glibc" ];
        };
        "21" = {
          spec = p: jre p "temurin-jre-bin-21";
        };
        "25" = {
          spec = p: jre p "temurin-jre-bin-25";
        };
      };
  };
}
