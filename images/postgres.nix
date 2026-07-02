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
# list, so a stub keeps llvm out of the build closure). `-flto` is then dropped
# from CFLAGS because plain binutils `ar` can't index gcc's slim LTO archives
# (libpgcommon.a); gcc + `-fdata-sections -ffunction-sections` without LTO is
# exactly how nixpkgs 24.11 built these same split outputs, and the dev/doc/man
# reference hygiene is handled by remove-references-to + archive-member
# selection, not by LTO.
#
# The init problem: distroless means no shell, so the docker-library
# entrypoint-script dance (initdb-on-first-boot) is impossible. The honest
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
# Caveat: initdb's `locale -a` import of libc system collations silently yields
# nothing here (popen needs a shell); C/POSIX/C.UTF-8 plus ICU collations
# (icuSupport is on — `--locale-provider=icu`) cover the container use case.
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
            # Drop -flto (clang-only here): plain binutils `ar` can't index
            # gcc's slim LTO objects in libpgcommon.a/libpgport.a, so linking
            # would fail. Section flags stay for --gc-sections-style dead code
            # removal, matching the pre-clang nixpkgs build of these outputs.
            # (No images/redis.nix-style musl check-skip needed: generic.nix
            # already disables the musl installcheck itself.)
            env = prev.env // {
              CFLAGS = "-fdata-sections -ffunction-sections";
            };
          })
        else
          base;
    in
    {
      contents = [ (vardeLib.relocate p "varde-postgres-root-${pg.version}" "runtime" pg) ];
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
