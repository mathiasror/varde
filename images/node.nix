# Minimal distroless Node.js runtime for JavaScript/TypeScript apps.
#
# Contract: drop your app at /app and start it as `node /app/main.js`. No shell,
# so npm `start` scripts won't run — point CMD at a real entry file. Built on the
# `-slim` (npm-less) Node packages, so there is no package manager in the image;
# install your dependencies in a builder stage and COPY node_modules in.
#
# Built for both libcs: the bare tag (e.g. :24) is musl; opt into glibc with the
# :24-glibc tag. `fhs = true` gives the image the matching libc + libstdc++/libgcc_s
# layout so native node addons (.node compiled against system libs) load correctly.
{ pkgs, vardeLib, lib }:
let
  # `p` is the libc's package set (pkgs for glibc, pkgs.pkgsMusl for musl).
  nodeSpec = p: node: {
    contents = [ (vardeLib.relocate p "varde-node-root-${node.version}" "runtime" node) ];
    entrypoint = [ "/runtime/bin/node" ];
    cmd = [ "/app/main.js" ];
    env = [
      "PATH=/runtime/bin"
      "NODE_ENV=production"
    ];
    fhs = true;
  };
in
{
  description = "Minimal distroless Node.js runtime for JavaScript/TypeScript apps";
  latest = "24"; # current default
  # Node 20 is intentionally omitted: it is EOL (April 2026) and nixpkgs marks it
  # insecure. Shipping it would contradict this project's security goal. Only
  # maintained LTS lines are published.
  variants = vardeLib.mkVariants pkgs {
    versions = {
      "22" = { spec = p: nodeSpec p p."nodejs-slim_22"; };
      "24" = { spec = p: nodeSpec p p."nodejs-slim_24"; };
    };
  };
}
