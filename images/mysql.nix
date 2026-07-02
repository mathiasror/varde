# Minimal distroless MySQL server (MySQL 8.4 LTS).
#
# Why MySQL and not MariaDB: this image has NO shell, and MySQL 8 initializes
# its data directory natively (`mysqld --initialize-insecure`), whereas
# MariaDB's `mariadb-install-db` is a shell script — a non-starter here.
# (nixpkgs' mysql80 reached EOL 2026-04-30 and was removed; 8.4 is the LTS.)
#
# glibc-only (`libcs = [ "glibc" ]`, the jre-17 precedent): pkgsMusl.mysql84
# does not even instantiate — its pinned protobuf_21 depends on
# abseil-cpp-20210324.2, which is marked broken on musl — and a from-source
# musl MySQL would be one of the heaviest builds in the repo even if it did.
# The bare tags (:8.4, :latest) therefore map to the glibc build.
#
# The stock nixpkgs mysql84 is used UNMODIFIED (no .override): there is no
# systemd flag to disable (unlike redis), boost is a bundled header-only build
# dep that never reaches the closure, and staying stock keeps the package
# substitutable from cache.nixos.org instead of a ~1h from-source compile.
# libfido2 (which drags systemd-minimal-libs) is build-closure-only: none of
# the binaries shipped below link it.
#
# The package output itself is NOT shipped whole: it is 302MB and reference-
# scans to a 756MB closure (mysql_config + pkgconfig leak gcc-wrapper,
# binutils, coreutils, bash and -dev outputs). Instead a pruned runtime is
# assembled under /runtime — mysqld, the mysql client, mysqladmin, mysqldump,
# the production plugins/components, english error messages and charsets —
# and `remove-references-to` strips the self-references mysqld embeds for its
# compiled-in defaults (basedir, plugin dir, share dir, sysconfdir). Every
# path default that breaks is re-pointed by a baked /etc/my.cnf (mysqld always
# reads /etc/my.cnf first), which also carries the container-sane defaults.
# The config file — not Cmd — holds the defaults on purpose: the one-time
# `--initialize-insecure` run replaces any Cmd args, but reads /etc/my.cnf
# just like a normal start, so both steps see the same datadir and paths.
#
# Runtime notes for a bare rootfs:
#   - datadir=/app/data; socket + pid file under sticky /tmp (there is no
#     /run/mysqld, the compiled default socket dir).
#   - bind-address=0.0.0.0 (reachable when published), port 3306.
#   - mysqlx=OFF: no X-plugin port 33060 or extra socket to care for.
#   - secure-file-priv=NULL: server-side import/export (LOAD DATA INFILE,
#     SELECT ... INTO OUTFILE) disabled — the secure distroless default.
#   - skip-name-resolve: no reverse DNS on connect; write grants against IPs
#     or '%' ('root'@'localhost' still matches socket connections).
#   - Only English server messages ship (lc_messages must stay en_US) and the
#     time-zone tables are empty (mysql_tzinfo_to_sql is not shipped); use
#     numeric offsets, e.g. SET time_zone = '+02:00'.
#   - mysqld refuses to run as root; the image runs as 1000:1000, and
#     /app (the WORKDIR) is owned by 1000, so --initialize can create
#     /app/data. Mount persistent volumes at /app so the ownership of the
#     mountpoint comes from the image.
#
# Contract (two steps, no shell — the entrypoint IS mysqld):
#   1) one-time init:  docker run --rm -v mysql-data:/app <img> --initialize-insecure
#   2) run:            docker run -d  -v mysql-data:/app -p 3306:3306 <img>
# Health check: docker exec <c> /runtime/bin/mysqladmin -u root ping
# (see examples/mysql/simple for a build-time-initialized demo).
{ pkgs, vardeLib, lib }:
let
  # `p` is the libc's package set; only glibc is enabled (see header).
  mysqlSpec =
    p:
    let
      mysql = p.mysql84;

      # Pruned runtime under /runtime. `remove-references-to` neutralizes the
      # embedded self store path (same-length dummy hash), so the pruned copy
      # does not drag the full 302MB package (and its leaked build-tool refs)
      # back into the image closure; /etc/my.cnf re-points every default that
      # relied on it.
      runtime = p.runCommand "varde-mysql-root-${mysql.version}" {
        nativeBuildInputs = [ p.removeReferencesTo ];
      } ''
        mkdir -p "$out/runtime/bin" "$out/runtime/lib/mysql" "$out/runtime/share/mysql"

        # Server + the ops tools you actually exec in a container: health
        # checks (mysqladmin ping), SQL administration (mysql) and backups
        # (mysqldump). Everything else in bin/ is test tooling, MyISAM-era
        # utilities, or scripts that need a shell (mysqld_safe & co).
        for b in mysqld mysql mysqladmin mysqldump; do
          cp -a ${mysql}/bin/"$b" "$out/runtime/bin/"
        done

        # Production plugins/components only — the nixpkgs build also installs
        # MySQL's test/example plugins, which are dead weight and attack
        # surface in a distroless image.
        cp -a ${mysql}/lib/mysql/plugin "$out/runtime/lib/mysql/plugin"
        rm -f "$out/runtime/lib/mysql/plugin"/*test* \
              "$out/runtime/lib/mysql/plugin"/*example* \
              "$out/runtime/lib/mysql/plugin"/*mock* \
              "$out/runtime/lib/mysql/plugin"/qa_auth_*.so \
              "$out/runtime/lib/mysql/plugin"/auth.so \
              "$out/runtime/lib/mysql/plugin"/mypluglib.so \
              "$out/runtime/lib/mysql/plugin"/conflicting_variables.so \
              "$out/runtime/lib/mysql/plugin"/adt_null.so \
              "$out/runtime/lib/mysql/plugin"/component_udf_*.so

        # Error messages (english only) + character set definitions.
        cp -a ${mysql}/share/mysql/english  "$out/runtime/share/mysql/english"
        cp -a ${mysql}/share/mysql/charsets "$out/runtime/share/mysql/charsets"

        chmod -R u+w "$out"
        find "$out" -type f -exec remove-references-to -t ${mysql} {} +
      '';

      # Baked defaults. mysqld reads /etc/my.cnf before anything else, for
      # BOTH `--initialize-insecure` and normal starts, and command-line args
      # still override it — so this is the robust place for path plumbing and
      # container-sane defaults in a shell-less image (a default Cmd would be
      # lost the moment the init step passes its own args).
      conf = p.writeTextDir "etc/my.cnf" ''
        # varde-mysql baked defaults. Override any of these per-run by passing
        # mysqld args (they win over this file), e.g.:
        #   docker run ... varde-mysql --port=3307
        [mysqld]
        # The store-path defaults were compiled out of the pruned runtime; the
        # relocated copies live under /runtime.
        basedir = /runtime
        plugin-dir = /runtime/lib/mysql/plugin
        lc-messages-dir = /runtime/share/mysql
        character-sets-dir = /runtime/share/mysql/charsets

        # Data lives under the writable, 1000-owned WORKDIR; sockets and pid
        # under sticky /tmp (there is no /run/mysqld in this image).
        datadir = /app/data
        socket = /tmp/mysql.sock
        pid-file = /tmp/mysqld.pid
        tmpdir = /tmp

        # Container-sane defaults: reachable when published; no X-plugin port;
        # no server-side file import/export; no reverse DNS on connect.
        bind-address = 0.0.0.0
        mysqlx = OFF
        secure-file-priv = NULL
        skip-name-resolve

        [client]
        socket = /tmp/mysql.sock
        character-sets-dir = /runtime/share/mysql/charsets
      '';
    in
    {
      contents = [
        runtime
        conf
      ];
      entrypoint = [ "/runtime/bin/mysqld" ];
      env = [ "PATH=/runtime/bin" ];
      # no cmd: defaults come from /etc/my.cnf (see above); `docker run <img>
      # <args>` appends mysqld flags, which override the config file.
    };
in
{
  description = "Minimal distroless MySQL 8.4 server";
  latest = "8.4";
  variants = vardeLib.mkVariants pkgs {
    versions."8.4" = {
      spec = mysqlSpec;
      # musl is uninstantiable (protobuf_21 -> abseil-cpp-20210324.2 is marked
      # broken on musl); the bare :8.4 / :latest tags map to glibc, like jre:17.
      libcs = [ "glibc" ];
    };
  };
}
