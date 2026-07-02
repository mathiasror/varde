# Minimal distroless PostgreSQL server.
#
# Relocates the nixpkgs postgresql package under /runtime (postgres + initdb +
# psql/pg_isready/pg_dump/... — binaries find their libs via RPATH, so no FHS
# layout is needed). Runs non-root (postgres refuses root anyway) as 1000:1000
# with the cluster at /app/data (PGDATA), inside the app-owned WORKDIR /app.
#
# Trimmed via package override flags (never source patches), for BOTH libcs:
#   - jitSupport = false      LLVM JIT drags clang/llvm into the build closure —
#                             on musl that's hours of from-source compiles that
#                             blow the 6h CI job limit (see images/redis.nix).
#   - systemdSupport = false  sd_notify is dead weight in a container, and the
#                             systemd closure drags clang/llvm/bpftools/tpm2-tss.
#   - pamSupport = false      no PAM stack (/etc/pam.d) exists in this image.
#   - perl/python/tclSupport = false
#                             PL/Perl, PL/Python and PL/Tcl would ship whole
#                             interpreter closures; dead weight in a base image.
#   - curlSupport = false     (18+) libpq's OAuth device-flow helper via
#                             libcurl — a client-side feature, dead in a server
#                             image, and keeps 16/17/18 feature parity.
# Kept: icu (collations), gssapi, openssl, lz4/zstd, libxml2, readline — and on
# 18+, liburing/numactl (tiny, and 18's async-IO defaults don't require them).
#
# Even with JIT off, nixpkgs force-builds postgres with a clang stdenv (for
# `-flto` section-GC) and names llvm in outputChecks.disallowedRequisites — on
# musl both mean compiling llvm+clang from source for hours. Both have override
# seams: `overrideCC` (only used to construct that clang stdenv; returning the
# set's default gcc stdenv means the clang argument is never even evaluated) and
# `llvmPackages` (with JIT off only forced through the disallowedRequisites
# list, so a stub keeps llvm out of the build closure). `-flto` is then swapped
# for `-fmerge-constants -Wl,--gc-sections` — verbatim the non-clang arm of
# these same CFLAGS in nixpkgs 24.11 — because plain binutils `ar` can't index
# gcc's slim LTO archives (libpgcommon.a). The link-time `--gc-sections` is
# load-bearing, not an optimization: libpgcommon/libpgport embed every output's
# path (the pg_config table) into every binary and shared library, and only
# section-GC strips the unused ones back out. Without it $lib/lib/*.so keeps a
# $dev path, and since $dev refers back to $lib (pg_config.env, pgxs) the build
# aborts with "cycle detected ... output 'dev' from output 'lib'".
#
# The init problem: there is no docker-library entrypoint-script dance
# (initdb-on-first-boot) — no coreutils to write one against. The honest
# contract is two explicit steps sharing a volume mounted at /app (the image's
# /app is owned 1000:1000, so a fresh named volume inherits that ownership):
#   1) one-time:  docker run --rm -i -v pgdata:/app \
#                   --entrypoint /runtime/bin/initdb <img> \
#                   -U postgres --pwfile=/dev/stdin <<<'secret'
#                 (initdb runs as uid 1000 and reads PGDATA=/app/data from the
#                 environment; LANG/LC_ALL=C.UTF-8 give a UTF8 cluster)
#   2) normal:    docker run -d -p 5432:5432 -v pgdata:/app <img>
# See examples/postgres/simple/ for the full walk-through.
#
# One concession to PostgreSQL's design: initdb drives every child `postgres`
# through popen(3)/system(3) — the sibling version probe (`postgres -V` in
# find_other_exec, src/common/exec.c), the `--boot` bootstrap run and the
# single-user post-bootstrap runs are all shell command LINES (quoting,
# redirections), and libc popen/system hardcode /bin/sh. In a shell-less image
# initdb dies on the very first probe with the misleading
#   initdb: error: program "postgres" is needed by initdb but was not found
#   in the same directory as "/runtime/bin/initdb"
# (find_other_exec folds popen's ENOENT into "not found"; both glibc and musl
# popen report the missing /bin/sh via posix_spawn). So this image — alone
# among varde images — ships a /bin/sh: busybox-sandbox-shell, the small
# static ash-only busybox that Nix itself mounts as /bin/sh in every Linux
# build sandbox. One self-contained binary, no other applets, no coreutils;
# the server still runs non-root with no package manager in sight.
#
# Entrypoint choices (operational flags live in the ENTRYPOINT so a user CMD
# can't accidentally drop them; later command-line -c flags override earlier
# ones, so they all stay overridable):
#   - unix_socket_directories=/tmp  nixpkgs compiles the default socket dir as
#     /run/postgresql, which doesn't exist (writable) here; /tmp is the image's
#     sticky world-writable dir (and upstream postgres' vanilla default).
#     PGHOST=/tmp points in-image libpq clients (docker exec psql/pg_isready)
#     at it, so they work with no -h flag.
#   - listen_addresses=*  a container-only address is useless in practice; this
#     is NOT a trust footgun: initdb's generated pg_hba.conf only allows local
#     and loopback connections, so remote access still requires the user to
#     provide an hba rule (e.g. CMD ["-c" "hba_file=/etc/postgresql/pg_hba.conf"]).
# No default CMD: `docker run <img> -c work_mem=64MB` appends straight to the
# entrypoint, and PGDATA supplies the data directory.
#
# Caveat: the backend's `locale -a` import of libc system collations stays
# minimal here — on musl nixpkgs applies Alpine's dont-use-locale-a patch (no
# `locale -a` at all), and on glibc the wrapped initdb finds only glibc's own
# C/POSIX/C.utf8 (no locale archive in the image); ICU collations (icuSupport
# is on — `--locale-provider=icu`) cover the container use case.
#
# Built for both libcs: the bare tag (e.g. :18) is musl; opt into glibc with
# :18-glibc. :latest is the newest stable major.
{ pkgs, vardeLib, lib }:
let
  # `p` is the libc's package set (pkgs for glibc, pkgs.pkgsMusl for musl).
  pgSpec =
    p: pgBase:
    let
      isMusl = p.stdenv.hostPlatform.isMusl;
      flags = {
        jitSupport = false;
        systemdSupport = false;
        pamSupport = false;
        perlSupport = false;
        pythonSupport = false;
        tclSupport = false;
        curlSupport = false;
      };
      # MUSL ONLY: on glibc, upstream's clang+LTO arrangement is Hydra's own
      # well-trodden path (clang substitutes from cache.nixos.org) — and forcing
      # gcc/no-LTO there tripped a lib->dev output-reference cycle on
      # postgresql 16. The surgery exists solely to keep the multi-hour clang/
      # llvm builds out of the musl closure.
      muslSurgery = {
        # Keep the package set's default (gcc) stdenv: generic.nix only calls
        # overrideCC to swap in a clang stdenv for -flto, and laziness means
        # the clang argument is never evaluated (see header).
        overrideCC = _stdenv: _cc: p.stdenv;
        # With JIT off, llvmPackages is only forced via
        # outputChecks.disallowedRequisites; a stub keeps the multi-hour musl
        # llvm build out of the closure (the check then trivially passes).
        llvmPackages = {
          llvm = {
            out = p.emptyDirectory;
            lib = p.emptyDirectory;
          };
        };
      };
      base = pgBase.override (flags // lib.optionalAttrs isMusl muslSurgery);
      pg =
        if isMusl then
          base.overrideAttrs (prev: {
            # Swap clang's -flto for nixpkgs 24.11's gcc arm of these exact
            # CFLAGS: plain binutils `ar` can't index gcc's slim LTO objects in
            # libpgcommon.a/libpgport.a, so -flto would break the link — but
            # the section flags alone are NOT a substitute. Without link-time
            # `-Wl,--gc-sections` the pg_config path table survives into
            # $lib/lib/*.so, whose $dev reference then trips Nix's
            # "cycle detected ... output 'dev' from output 'lib'" (see header).
            # (No images/redis.nix-style musl check-skip needed: generic.nix
            # already disables the musl installcheck itself.)
            env = prev.env // {
              CFLAGS = "-fdata-sections -ffunction-sections -fmerge-constants -Wl,--gc-sections";
            };
          })
        else
          base;
      # initdb cannot run without /bin/sh (see header: popen/system for the
      # version probe and every bootstrap `postgres` run). The ash-only static
      # busybox Nix uses as its sandbox shell — a single self-contained binary
      # (closure: itself), the same role on both libcs.
      sh = p.runCommand "varde-postgres-sh" { } ''
        mkdir -p "$out/bin"
        ln -s ${p.busybox-sandbox-shell}/bin/busybox "$out/bin/sh"
      '';
    in
    {
      contents = [
        (vardeLib.relocate p "varde-postgres-root-${pg.version}" "runtime" pg)
        sh
      ];
      entrypoint = [
        "/runtime/bin/postgres"
        "-c"
        "unix_socket_directories=/tmp"
        "-c"
        "listen_addresses=*"
      ];
      env = [
        "PATH=/runtime/bin"
        "PGDATA=/app/data"
        "PGHOST=/tmp"
      ];
      # `docker stop`'s default SIGTERM is postgres "smart" shutdown: wait for
      # every session to end — in a container that means idling until the stop
      # timeout SIGKILLs the daemon, and the next boot pays crash recovery.
      # SIGINT is "fast" shutdown: abort transactions, disconnect, exit clean.
      stopSignal = "SIGINT";
      # no fhs: the nixpkgs postgres binaries find their libs via RPATH.
    };
in
{
  description = "Minimal distroless PostgreSQL server";
  latest = "18"; # newest stable major in the pinned nixpkgs (19 is still beta)
  variants = vardeLib.mkVariants pkgs {
    versions = {
      "16" = { spec = p: pgSpec p p.postgresql_16; };
      "17" = { spec = p: pgSpec p p.postgresql_17; };
      "18" = { spec = p: pgSpec p p.postgresql_18; };
    };
  };
}
