{
  description = "varde — minimal, secure, Nix-built distroless base images";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  # SBOM/scan tooling pin, separate from the image-contents `nixpkgs` above.
  # The tooling used to ride the weekly bump, so when the July 13/20 2026 bumps
  # landed a nixpkgs where sbomnix-1.8.0 no longer built (its dependency
  # python3.14-df-diskcache-0.0.2 fails to compile), every CI build job went
  # red for two weeks — a tooling breakage, not an image problem. Pinned to an
  # exact rev (the July 27 2026 nixos-unstable bump, where sbomnix builds
  # again) so it moves only when a human edits this line; bump-lock.yml
  # deliberately updates only `nixpkgs`. A weekly bump can now only break the
  # image contents actually being rebuilt, never the machinery that packages
  # them. Follows nothing — nixpkgs has no inputs of its own.
  inputs.nixpkgs-tools.url = "github:NixOS/nixpkgs/624af665418d3c65d544145b4d34ad696439570e";

  outputs =
    { self, nixpkgs, nixpkgs-tools }:
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

      # p11-kit 0.26.2's test-server.sh is racy when gnutls's p11tool is absent
      # (always, in the sandbox): it starts p11-kit-server, skips its only test,
      # then teardown `kill`s a server PID that has often already exited — and
      # common/test-init.sh runs under `set -euf`, so the failed kill fails the
      # whole check phase. Run 30795989594 shows the same drv passing in
      # jre:21-musl (arm64) and failing jre:25-musl (arm64) two minutes later —
      # a pure race, upstream-unfixed as of 0.26.2. Tolerating the dead server
      # keeps the other 66 checks (and the skip) intact. Musl-only on purpose:
      # glibc builds resolve from cache.nixos.org, and touching their p11-kit
      # drv would cache-miss every glibc image for no gain; musl builds come
      # from source into the varde cachix anyway, so only they pay the one-time
      # rebuild of the p11-kit -> gnutls -> cups -> temurin chain.
      p11kitTeardownRaceFix = final: prev: {
        p11-kit =
          if prev.stdenv.hostPlatform.isMusl then
            prev.p11-kit.overrideAttrs (old: {
              postPatch =
                (old.postPatch or "")
                + ''
                  substituteInPlace p11-kit/test-server.sh \
                    --replace-fail 'kill "$P11_KIT_SERVER_PID"' 'kill "$P11_KIT_SERVER_PID" 2>/dev/null || :'
                '';
            })
          else
            prev.p11-kit;
      };
      # Sole nixpkgs import for image contents: evalFor and entriesFor must
      # share one instantiation or their store paths could silently diverge.
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ p11kitTeardownRaceFix ];
        };

      # Evaluate every module once for a system: { <image> = { description; latest?; variants; }; }
      evalFor =
        system:
        let
          pkgs = pkgsFor system;
        in
        lib.mapAttrs (image: mod: mod { inherit pkgs vardeLib lib; }) modules;

      # One flat list of every {image, tag, attr, sbomName, drv, sbomApp} for a
      # system. String fields are system-independent (used to derive CI matrix).
      entriesFor =
        system:
        let
          pkgs = pkgsFor system;
          # SBOM machinery from the pinned input (see `nixpkgs-tools` above) —
          # image contents keep coming from the moving `pkgs`.
          toolsPkgs = import nixpkgs-tools { inherit system; };
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
              sbomApp = vardeLib.buildSbomApp pkgs toolsPkgs {
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
