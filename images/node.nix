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
{
  pkgs,
  vardeLib,
  lib,
}:
let
  # `p` is the libc's package set (pkgs for glibc, pkgs.pkgsMusl for musl).
  #
  # nodejs-slim's usable payload is the single bin/node ELF — but that binary
  # embeds its configure echoes (process.config): inert references to the dev
  # output of every library it was built against, through which bash
  # (icu4c-dev's icu-config, zstd-dev -> zstd-bin) and the sqlite3 CLI
  # (sqlite-dev -> sqlite-bin) rode into the closure. Ship a copy of just the
  # ELF with those strings dummied out; the genuine RPATH entries point at lib
  # outputs and are untouched. The stock `node` stays the metadata source;
  # only node.version is dereferenced.
  nodeSpec =
    p: node:
    let
      # The dev (and sqlite's bin) outputs of node's own buildInputs — the
      # exact set the binary can reference, resolved from the package itself
      # so a nixpkgs bump cannot silently add one this misses. The closure
      # guard in lib/default.nix backstops the -dev half of that claim; -bin
      # outputs (the sqlite3 CLI) only ever arrive via their -dev referrer,
      # which severing -dev cuts off.
      inertRefs = lib.unique (
        lib.concatMap (
          d: lib.optional (d ? dev) d.dev ++ lib.optional (lib.getName d == "sqlite" && d ? bin) d.bin
        ) (node.buildInputs or [ ])
        ++ [ p.bashNonInteractive ]
      );

      # node links libuvwasi.so at runtime (uvwasi's lib dir is in the RPATH),
      # but uvwasi's single output also ships headers and a pkg-config file
      # that reference libuv's DEV output — a transitive -dev leak the strip
      # below can't cut without breaking the loader. Ship a lib-only copy of
      # uvwasi and retarget node's RPATH entry at it.
      uvwasi = lib.findFirst (d: lib.getName d == "uvwasi") null (node.buildInputs or [ ]);
      uvwasiLib = lib.mapNullable (
        uv:
        (p.runCommand "varde-uvwasi-lib" {
          nativeBuildInputs = [ p.buildPackages.removeReferencesTo ];
          disallowedRequisites = [ uv ] ++ inertRefs;
        })
          ''
            mkdir -p "$out"
            cp -a ${uv}/lib "$out/lib"
            chmod -R u+w "$out/lib"
            rm -rf "$out/lib/pkgconfig" "$out"/lib/*.la
            find "$out/lib" -type f -exec remove-references-to \
              -t ${uv} \
              ${lib.concatMapStringsSep " " (t: "-t ${t}") inertRefs} \
              {} +
          ''
      ) uvwasi;
      stripped =
        (p.runCommand "varde-node-root-${node.version}" {
          nativeBuildInputs = [
            p.buildPackages.removeReferencesTo
            p.buildPackages.patchelf
          ];
          disallowedRequisites = inertRefs ++ [ node ] ++ lib.optional (uvwasi != null) uvwasi;
        })
          ''
            mkdir -p "$out/runtime/bin"
            cp ${node}/bin/node "$out/runtime/bin/node"
            chmod u+w "$out/runtime/bin/node"
            ${lib.optionalString (uvwasi != null) ''
              # Retarget the RPATH's uvwasi entry at the lib-only copy BEFORE
              # the strip below dummies the original hash out.
              patchelf --set-rpath \
                "$(patchelf --print-rpath "$out/runtime/bin/node" | sed "s|${uvwasi}|${uvwasiLib}|g")" \
                "$out/runtime/bin/node"
            ''}
            # -t ''${node}: the binary also embeds its own store path
            # (process.config's "node_prefix") — inert config metadata of the
            # same class as the dev echoes, and it must go or this copy's own
            # disallowedRequisites rejects the build. Same for the leftover
            # uvwasi /include echoes after the RPATH retarget above.
            remove-references-to \
              -t ${node} \
              ${lib.optionalString (uvwasi != null) "-t ${uvwasi}"} \
              ${lib.concatMapStringsSep " " (t: "-t ${t}") inertRefs} \
              "$out/runtime/bin/node"
          '';
    in
    {
      contents = [ stripped ];
      entrypoint = [ "/runtime/bin/node" ];
      cmd = [ "/app/main.js" ];
      env = [
        "PATH=/runtime/bin"
        "NODE_ENV=production"
      ];
      fhs = true;

      # SBOM: NVD files Node.js CVEs under `nodejs:node.js`, so the vendor=name
      # CPE sbomnix derives (nodejs-slim:nodejs-slim) matches nothing. Scan
      # metadata only.
      sbomExtraComponents = [
        (vardeLib.sbomComponent {
          vendor = "nodejs";
          product = "node.js";
          version = node.version;
        })
      ];
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
      "22" = {
        spec = p: nodeSpec p p."nodejs-slim_22";
      };
      "24" = {
        spec = p: nodeSpec p p."nodejs-slim_24";
      };
    };
  };
}
