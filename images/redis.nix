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
  redisSpec = p: {
    contents = [ (vardeLib.relocate p "varde-redis-root-${p.redis.version}" "runtime" p.redis) ];
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
