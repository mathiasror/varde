# Minimal distroless nginx — non-root, listens on :8080.
#
# Relocates the nixpkgs nginx package under /runtime (finds its libs via RPATH,
# so no FHS layout is needed) and ships a non-root default config + mime.types at
# /etc/nginx. nginx runs as 1000:1000: it listens on 8080 (unprivileged) and
# writes its pid and temp files under the sticky /tmp. Static files are served
# from /app.
#
# Built for both libcs: the bare tag (:latest) is musl; opt into glibc with
# :latest-glibc.
#
# Contract: COPY your static site into /app (see examples/nginx/). To use your
# own nginx config, override the entrypoint's -c path or bind-mount over
# /etc/nginx/nginx.conf.
{
  pkgs,
  vardeLib,
  lib,
}:
let
  # `p` is the libc's package set (pkgs for glibc, pkgs.pkgsMusl for musl).
  nginxSpec =
    p:
    let
      # Config + mime.types at in-image absolute paths (the Nix store is not in
      # the image; mime.types is copied from the nginx package at build time).
      conf = p.runCommand "varde-nginx-conf" { } ''
        mkdir -p "$out/etc/nginx"
        cp ${./nginx.conf} "$out/etc/nginx/nginx.conf"
        cp ${p.nginx}/conf/mime.types "$out/etc/nginx/mime.types"
      '';
    in
    {
      contents = [
        (vardeLib.relocate p "varde-nginx-root-${p.nginx.version}" "runtime" p.nginx)
        conf
      ];
      # -p sets a writable prefix (/tmp) for any relative default paths; -e
      # replaces the compile-time default error log (/var/log/nginx/error.log),
      # which nginx opens BEFORE reading the config and alerts about on every
      # start (the config itself already logs to /dev/stderr); -c points at our
      # config; daemon off so PID 1 is nginx.
      entrypoint = [
        "/runtime/bin/nginx"
        "-p"
        "/tmp"
        "-e"
        "stderr"
        "-c"
        "/etc/nginx/nginx.conf"
        "-g"
        "daemon off;"
      ];
      env = [ "PATH=/runtime/bin" ];
      # `docker stop`'s default SIGTERM is nginx "fast shutdown": workers exit
      # at once and in-flight responses are cut mid-transfer. SIGQUIT is the
      # graceful one — stop accepting, finish open requests, then exit (the
      # official nginx image sets STOPSIGNAL SIGQUIT for the same reason).
      stopSignal = "SIGQUIT";

      # SBOM: NVD files open-source nginx CVEs under vendor `f5` (nginx:nginx
      # stopped being used for new entries after the F5 acquisition), and
      # under BOTH products `nginx` and `nginx_open_source` — e.g.
      # CVE-2025-23419 is only on f5:nginx while CVE-2024-7347 is only on
      # f5:nginx_open_source — so one CPE misses whichever product the other
      # entries use, silently. The vendor=name CPE syft derives matches
      # neither. Scan metadata only; the distinct `name` keeps the bom-refs
      # unique.
      sbomExtraComponents = [
        (vardeLib.sbomComponent {
          vendor = "f5";
          product = "nginx";
          version = p.nginx.version;
          # syft's Nix cataloger also emits the legacy `nginx:nginx`; NVD's
          # nginx:nginx CVEs are a subset of f5:nginx's, so it only doubles.
          supersedes = [ "nginx:nginx" ];
        })
        (vardeLib.sbomComponent {
          vendor = "f5";
          product = "nginx_open_source";
          version = p.nginx.version;
        })
      ];
    };
in
{
  description = "Minimal distroless nginx (non-root, listens on :8080)";
  latest = "latest";
  variants = vardeLib.mkVariants pkgs {
    versions."latest" = {
      spec = nginxSpec;
    };
  };
}
