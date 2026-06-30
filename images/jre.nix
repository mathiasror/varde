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
{ pkgs, vardeLib, lib }:
let
  variant = jre: {
    contents = [
      (pkgs.runCommand "varde-jre-root-${jre.version}" { } ''
        mkdir -p "$out/runtime"
        # Resolve the real JRE home (handles flat or nested nixpkgs layouts) so
        # /runtime is a self-contained Java home with java at /runtime/bin/java.
        home="$(dirname "$(dirname "$(readlink -f ${jre}/bin/java)")")"
        cp -a "$home"/. "$out/runtime/"
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
  variants = {
    "17" = variant pkgs."temurin-jre-bin-17";
    "21" = variant pkgs."temurin-jre-bin-21";
    "25" = variant pkgs."temurin-jre-bin-25";
  };
}
