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
{
  pkgs,
  vardeLib,
  lib,
}:
let
  # Reconfigure the stock nixpkgs php for a distroless container. `p` is the
  # libc's package set (pkgs for glibc, pkgs.pkgsMusl for musl), so added build
  # inputs match the interpreter's libc.
  mkPhp =
    p: basePhp:
    (basePhp.override {
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
          (builtins.filter (f: !(lib.isString f && lib.hasPrefix "PROG_SENDMAIL=" f)) prev.configureFlags)
          ++ [
            # Core xml/libxml, normally enabled as a side effect of pearSupport.
            "--enable-xml"
            "--with-libxml"
            # The default PROG_SENDMAIL (system-sendmail) is a bash script
            # that would drag a shell into the closure. Compile in the
            # conventional FHS path instead; it doesn't exist in the image, so
            # mail() fails cleanly (send mail via SMTP from the app instead).
            "PROG_SENDMAIL=/usr/sbin/sendmail"
          ];
      };
    }).withExtensions
      (
        { all, enabled }:
        let
          # openldap doesn't compile on musl (openssl 3.x deprecation fallout
          # in its TLS layer), and LDAP from a distroless PHP is niche. Dropped
          # on BOTH libcs so the musl and glibc tags stay behavior-identical.
          kept = builtins.filter (e: e != all.ldap) enabled;

          # libavif's output bundles a gdk-pixbuf loader and a thumbnailer (a
          # bash wrapper script); through php-gd -> gd -> libavif that dragged
          # bash, gdk-pixbuf and glib into the image closure. (PROG_SENDMAIL
          # above killed the previous shell route; this one arrived with gd's
          # avif support.) Rebuild libavif without the pixbuf side-outputs —
          # gd only links lib/libavif.so — and point both gd and the gd
          # extension at the fixed one. The extension's --with-external-gd
          # configure flag embeds gd.dev's store path, so the flag is
          # rewritten alongside buildInputs. Done here in the extension map
          # because php.override { packageOverrides = …; } is silently dropped
          # for buildEnv results (see the composition note below).
          libavif = p.libavif.overrideAttrs (prev: {
            postInstall = (prev.postInstall or "") + ''
              rm -rf "$out/bin" "$out/libexec" "$out/share/thumbnailers" "$out/lib/gdk-pixbuf-2.0"
            '';
          });
          # libXpm compiles in absolute paths to gzip and uncompress and execs
          # them to read compressed .xpm files — the final shell route (gzip
          # ships bash scripts: zgrep, zcat & co): php-gd -> gd -> libXpm ->
          # gzip -> bash, identically on both libcs. Sever the compressed-XPM
          # exec paths: plain .xpm keeps working; opening a .xpm.gz/.xpm.Z now
          # fails cleanly instead of exec'ing a compressor the image doesn't
          # ship anyway.
          libxpm = p.libxpm.overrideAttrs (prev: {
            nativeBuildInputs = (prev.nativeBuildInputs or [ ]) ++ [
              p.buildPackages.removeReferencesTo
            ];
            postFixup = (prev.postFixup or "") + ''
              find "$out" -type f -exec remove-references-to \
                -t ${p.gzip} -t ${p.ncompress} {} +
            '';
          });
          gd = p.gd.override { inherit libavif libxpm; };

          # gettext (linked by ext-gettext for libintl — a real runtime dep on
          # musl, where libintl doesn't live in the libc) ships bash scripts
          # in bin/ (gettext.sh, autopoint, gettextize) — the libc-side route
          # by which a shell entered the musl images. Only lib/ is needed.
          gettext = p.gettext.overrideAttrs (prev: {
            postFixup = (prev.postFixup or "") + ''
              rm -rf "$out/bin"
            '';
          });

          # Extension-dependency swaps, applied in the map below: the
          # buildInputs element is swapped by name, and any configure flag
          # embedding the old store path is rebuilt fresh (replaceStrings
          # would keep the original flag's string context, so the stock
          # package — and its bash-carrying tail — would linger as a build
          # input of the extension).
          depSwaps = {
            gd = {
              old = "gd";
              new = gd;
              flagPrefix = "--with-external-gd=";
              newFlag = "--with-external-gd=${gd.dev}";
            };
            gettext = {
              old = "gettext";
              new = gettext;
              flagPrefix = "--with-gettext=";
              newFlag = "--with-gettext=${gettext}";
            };
          };
          swapDeps =
            e:
            if !(depSwaps ? ${e.extensionName or ""}) then
              e
            else
              let
                s = depSwaps.${e.extensionName};
              in
              e.overrideAttrs (prev: {
                buildInputs = map (b: if lib.getName b == s.old then s.new else b) prev.buildInputs;
                configureFlags = map (
                  f: if lib.hasPrefix s.flagPrefix (toString f) then s.newFlag else f
                ) prev.configureFlags;
              });
          keptFixed = map swapDeps kept;
        in
        # On musl, skip every extension's own `make test` — same lesson as
        # images/redis.nix, applied wholesale instead of per-extension
        # whack-a-mole. The upstream .phpt suites assume glibc semantics:
        # gettext's tests expect glibc locale behavior (setlocale("en_US") +
        # ngettext plural rules), which musl's C-only locales can't satisfy,
        # so all 6 of them fail — while the extension itself works fine on
        # musl (Alpine ships php-gettext). glibc keeps running the full
        # suites; the musl images' runtime proof is CI's docker smoke test
        # plus the e2e example, which exercise the actual interpreter and
        # extensions.
        #
        # Composition note: php.buildEnv's generated extension ini dedupes by
        # extension name with the enabled list taking precedence over drvs
        # pulled in via internalDeps, and overrideAttrs preserves
        # extensionName/internalDeps/zendExtension — so mapping over the
        # enabled list keeps load order intact and the image only ever loads
        # the no-check drvs. Extensions that others name in internalDeps (pdo,
        # mysqlnd, dom, session) are additionally built in their original
        # check-enabled form as build-time header deps of their dependents;
        # that's harmless: pdo and session ship doCheck = false upstream,
        # ext/mysqlnd has no test suite at all, and dom's passes on musl. (The
        # cleaner-looking `php.override { packageOverrides = …; }`, which
        # would rewrite the scope internalDeps resolve from, is silently
        # dropped for buildEnv results like php83 — verified by drv-hash
        # comparison — so this is the deepest hook available.)
        if p.stdenv.hostPlatform.isMusl then
          map (
            e:
            e.overrideAttrs (_: {
              doCheck = false;
            })
          ) keptFixed
        else
          keptFixed
      );

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
      "8.3" = {
        spec = p: phpSpec p p.php83;
      };
      "8.4" = {
        spec = p: phpSpec p p.php84;
      };
      "8.5" = {
        spec = p: phpSpec p p.php85;
      };
    };
  };
}
