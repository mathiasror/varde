{
  description = "varde — minimal, secure, Nix-built distroless base images";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      # Linux-only: Nix can't build a Linux image on Darwin without a Linux builder.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: lib.genAttrs systems f;
      vardeLib = import ./lib { inherit nixpkgs; };

      # Auto-discover image modules. Adding images/<name>.nix is all it takes for
      # a new image to appear in `nix build`, the SBOM apps, and CI.
      modules = lib.mapAttrs' (
        fname: _: lib.nameValuePair (lib.removeSuffix ".nix" fname) (import (./images + "/${fname}"))
      ) (lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".nix" n) (builtins.readDir ./images));

      # Dots are illegal in `nix build .#attr` paths, so 3.12 -> 3_12 for attrs;
      # the registry tag keeps the real "3.12".
      sanitize = lib.replaceStrings [ "." ] [ "_" ];

      # Evaluate every module once for a system: { <image> = { description; latest?; variants; }; }
      evalFor =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        lib.mapAttrs (image: mod: mod { inherit pkgs vardeLib lib; }) modules;

      # One flat list of every {image, tag, attr, sbomName, drv, sbomApp} for a
      # system. String fields are system-independent (used to derive CI matrix).
      entriesFor =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        lib.concatLists (
          lib.mapAttrsToList (
            image: m:
            lib.mapAttrsToList (tag: spec: {
              inherit image tag;
              libc = spec.libc or "glibc";
              attr = "image-${image}-${sanitize tag}";
              sbomName = "sbom-${image}-${sanitize tag}";
              drv = vardeLib.buildImage pkgs {
                name = "varde-${image}";
                inherit tag;
                inherit (m) description;
                inherit spec;
              };
              sbomApp = vardeLib.buildSbomApp pkgs {
                name = "varde-${image}-${sanitize tag}";
                inherit spec;
              };
            }) m.variants
          ) (evalFor system)
        );

      # Which tag each image publishes as :latest (module-declared; falls back to
      # the sole variant for single-variant images like static/glibc/musl). A multi-variant
      # module MUST declare `latest` — otherwise picking one silently (e.g. the
      # alphabetically-first, oldest tag) would be a footgun, so error instead.
      latestTags = lib.mapAttrs (
        image: m:
        if m ? latest then
          m.latest
        else if lib.length (lib.attrNames m.variants) == 1 then
          lib.head (lib.attrNames m.variants)
        else
          throw "image '${image}' has multiple variants but no `latest`; set `latest = \"<tag>\";` in images/${image}.nix"
      ) (evalFor "x86_64-linux");
    in
    {
      packages = forAllSystems (
        system:
        let
          attrs = lib.listToAttrs (map (e: lib.nameValuePair e.attr e.drv) (entriesFor system));
        in
        attrs // lib.optionalAttrs (attrs ? "image-jre-21-musl") { default = attrs."image-jre-21-musl"; }
      );

      apps = forAllSystems (
        system: lib.listToAttrs (map (e: lib.nameValuePair e.sbomName e.sbomApp) (entriesFor system))
      );

      # `nix eval --json .#ciMatrix`     -> [{image,tag,attr,sbomName,libc}, ...]
      # `nix eval --json .#latestTags`   -> {jre="21"; python="3.13"; ...}  (version; CI resolves default libc)
      # `nix eval --json .#imageAliases` -> {go="static"; rust="glibc";}    (published as mirror digests)
      ciMatrix = map (e: { inherit (e) image tag attr sbomName libc; }) (entriesFor "x86_64-linux");
      inherit latestTags;
      imageAliases = {
        go = "static";
        rust = "glibc";
      };
    };
}
