# Minimal distroless PHP runtime for PHP apps.
#
# Contract: drop your app at /app/index.php (override CMD for a different entry
# file). The entrypoint is the CLI SAPI (/runtime/bin/php); the image also ships
# php-fpm at /runtime/bin/php-fpm — override the entrypoint to serve FastCGI
# behind a web server (e.g. varde-nginx):
#   ENTRYPOINT ["/runtime/bin/php-fpm", "-F", "-y", "/app/php-fpm.conf"]
#
# Extensions: nixpkgs' DEFAULT extension set for each version (bcmath curl dom
# fileinfo filter gd iconv intl mbstring opcache openssl pdo_mysql pdo_pgsql
# pdo_sqlite session simplexml sockets sodium tokenizer xml* zip …) — the same
# set `nix shell nixpkgs#php84` gives you, and enough for Laravel/Symfony/
# WordPress-class apps. Extensions load via the generated ini in the default
# PHP_INI_SCAN_DIR (/runtime/lib); ADD your own ini dir rather than replacing:
#   ENV PHP_INI_SCAN_DIR=/runtime/lib:/app/php.d
# There is deliberately NO pear/pecl/phpize in the image: pecl is a package
# manager (out of scope for a distroless runtime, like pip/npm), and pear's
# launchers are bash scripts that would drag a shell into the closure. Need a
# different set? Build your own runtime with Nix (php84.withExtensions /
# php84.buildEnv) and relocate it exactly like this module does.
#
# Built for both libcs: the bare tag (e.g. :8.4) is musl; opt into glibc with
# the :8.4-glibc tag. No FHS layout: the interpreter and every extension are
# Nix-built and find their libraries via RPATH.
{ pkgs, vardeLib, lib }:
let
  # Reconfigure the stock nixpkgs php for a distroless container. `p` is the
  # libc's package set (pkgs for glibc, pkgs.pkgsMusl for musl), so added build
  # inputs match the interpreter's libc.
  mkPhp =
    p: basePhp:
    basePhp.override {
      # php-fpm's sd_notify support links libsystemd, whose closure on musl
      # drags in clang/llvm — same lesson as images/redis.nix. Useless under a
      # container supervisor anyway.
      systemdSupport = false;
      # --with-valgrind only embeds debug-hint headers at build time; dropping
      # it spares the musl variants from building valgrind at all.
      valgrindSupport = false;
      # Keep the two SAPIs that matter in a container: cli (the entrypoint) and
      # fpm. php-cgi and phpdbg are a full ~16 MB interpreter binary each.
      cgiSupport = false;
      phpdbgSupport = false;
      # No PEAR (see header). pearSupport also gates the core ext/libxml and
      # ext/xml that the shared dom/simplexml/soap/xml* extensions need at
      # runtime, so re-add exactly those configure flags below.
      pearSupport = false;
      phpAttrsOverrides = final: prev: {
        buildInputs = prev.buildInputs ++ [ p.libxml2.dev ];
        configureFlags =
          (builtins.filter (
            f: !(lib.isString f && lib.hasPrefix "PROG_SENDMAIL=" f)
          ) prev.configureFlags)
          ++ [
            # Core xml/libxml, normally enabled as a side effect of pearSupport.
            "--enable-xml"
            "--with-libxml"
            # The default PROG_SENDMAIL (system-sendmail) is a bash script — the
            # last shell reference in the closure. Compile in the conventional
            # FHS path instead; it doesn't exist in the image, so mail() fails
            # cleanly (send mail via SMTP from the app instead).
            "PROG_SENDMAIL=/usr/sbin/sendmail"
          ];
      };
    };

  phpSpec =
    p: basePhp:
    let
      php = mkPhp p basePhp;
    in
    {
      contents = [ (vardeLib.relocate p "varde-php-root-${php.version}" "runtime" php) ];
      entrypoint = [ "/runtime/bin/php" ];
      cmd = [ "/app/index.php" ];
      env = [
        "PATH=/runtime/bin"
        # Where the extension-loading ini lives after relocation. Set explicitly
        # so the mechanism is discoverable; append your own dir (see header).
        "PHP_INI_SCAN_DIR=/runtime/lib"
      ];
      # no fhs: extensions are Nix-built and find their libs via RPATH.
    };
in
{
  description = "Minimal distroless PHP runtime for PHP apps";
  latest = "8.5"; # newest stable release line
  # PHP 8.2 is intentionally omitted: it is security-fixes-only and reaches end
  # of life 2026-12-31; only fully maintained release lines are published.
  variants = vardeLib.mkVariants pkgs {
    versions = {
      "8.3" = { spec = p: phpSpec p p.php83; };
      "8.4" = { spec = p: phpSpec p p.php84; };
      "8.5" = { spec = p: phpSpec p p.php85; };
    };
  };
}
