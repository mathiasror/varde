# Minimal distroless Redis server.
#
# Relocates the nixpkgs redis package under /runtime (redis-server + redis-cli),
# which finds its libraries via RPATH, so no FHS layout is needed. Runs non-root
# (redis needs no privileges) and writes to the inherited WORKDIR /app.
#
# Built for both libcs: the bare tag (:latest) is musl; opt into glibc with
# :latest-glibc.
#
# Contract: run as-is (redis binds 0.0.0.0:6379 with defaults), or pass a config
# by overriding CMD: `CMD ["/app/redis.conf"]` (see examples/redis/).
{ pkgs, vardeLib, lib }:
let
  # `p` is the libc's package set (pkgs for glibc, pkgs.pkgsMusl for musl).
  redisSpec =
    p:
    let
      # sd_notify is dead weight in a container (no systemd to talk to), and
      # systemd's build closure drags in clang/llvm/bpftools/tpm2-tss — on musl
      # that's hours of from-source compiles that blow the 6h CI job limit.
      #
      # On musl the in-sandbox TCL test suite dies instantly ("Error: Connection
      # reset by peer") on both arches; the same suite passes on glibc, so keep
      # it there. The image's real runtime proof is CI's docker smoke test + the
      # e2e example, which exercise the actual redis-server binary.
      redis =
        (p.redis.override { withSystemd = false; }).overrideAttrs (
          lib.optionalAttrs p.stdenv.hostPlatform.isMusl { doCheck = false; }
        );
    in
    {
      contents = [ (vardeLib.relocate p "varde-redis-root-${redis.version}" "runtime" redis) ];
      entrypoint = [ "/runtime/bin/redis-server" ];
      env = [ "PATH=/runtime/bin" ];
      # no fhs: the nixpkgs redis binary finds its libs via RPATH.
    };
in
{
  description = "Minimal distroless Redis server";
  latest = "latest";
  variants = vardeLib.mkVariants pkgs {
    versions."latest" = { spec = redisSpec; };
  };
}
