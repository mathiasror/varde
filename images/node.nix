# Minimal distroless Node.js runtime for JavaScript/TypeScript apps.
#
# Contract: drop your app at /app and start it as `node /app/main.js`. No shell,
# so npm `start` scripts won't run — point CMD at a real entry file. Built on the
# `-slim` (npm-less) Node packages, so there is no package manager in the image;
# install your dependencies in a builder stage and COPY node_modules in.
{ pkgs, vardeLib, lib }:
let
  # fhs = true gives the image an FHS glibc + libstdc++/libgcc_s layout so that
  # native node addons (.node files compiled against system libs) load correctly.
  variant = node: {
    contents = [ (vardeLib.relocate pkgs "varde-node-root-${node.version}" "runtime" node) ];
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
  variants = {
    "22" = variant pkgs."nodejs-slim_22";
    "24" = variant pkgs."nodejs-slim_24";
  };
}
