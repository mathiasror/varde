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
{ pkgs, vardeLib, lib }:
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
  };
in
{
  description = "Minimal distroless Temurin JRE for JVM apps";
  latest = "21"; # current default LTS
  variants = vardeLib.mkVariants pkgs {
    versions = {
      # No aarch64 Alpine/musl Temurin for 17 -> glibc-only.
      "17" = {
        spec = p: jreSpec p p."temurin-jre-bin-17";
        libcs = [ "glibc" ];
      };
      "21" = { spec = p: jreSpec p p."temurin-jre-bin-21"; };
      "25" = { spec = p: jreSpec p p."temurin-jre-bin-25"; };
    };
  };
}
