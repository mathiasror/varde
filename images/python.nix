# Minimal distroless CPython runtime for Python apps.
#
# Contract: drop your app at /app/main.py (override CMD for a different module).
# No shell, so the interpreter runs your script directly. These interpreters
# ship no `pip` binary (only the inert `ensurepip` stdlib module), so the base
# is already package-manager-free — install deps in a builder stage and COPY
# them in (see examples/python/). `fhs = true` provides an FHS libc so wheels'
# externally-compiled .so extensions load at runtime.
#
# Built for both libcs: the bare tag (e.g. :3.13) is musl; opt into glibc with
# the :3.13-glibc tag. musl wheels are the musllinux ones; glibc wheels manylinux.
{
  pkgs,
  vardeLib,
  lib,
}:
let
  # `p` is the libc's package set (pkgs for glibc, pkgs.pkgsMusl for musl).
  #
  # The interpreter ships as a STRIPPED COPY rather than a relocate-symlink:
  # stock CPython's runtime closure contains bash (bin/python3-config is a
  # bash script, subprocess.py hardcodes the store bash as its shell=True
  # default, and a few build-material scripts carry bash shebangs), and any
  # symlink to the stock output drags that whole closure back in. The copy
  # drops the build-material files, repoints the remaining bin/ shebangs at
  # the in-image /runtime, and dummies out the inert leftover references (the
  # images/mysql.nix precedent). The stock `py` stays the metadata source;
  # only py.version is dereferenced. The stock python3 keeps substituting
  # from the caches — the copy is a seconds-long runCommand on top.
  pySpec =
    p: py:
    let
      stripped =
        (p.runCommand "varde-python-root-${py.version}" {
          nativeBuildInputs = [
            p.buildPackages.removeReferencesTo
            p.buildPackages.patchelf
          ];
          # Build-time proof (house style, images/rabbitmq.nix): the copy may
          # reference neither the stdenv bash nor the stock interpreter.
          disallowedRequisites = [
            p.bashNonInteractive
            py
          ];
        })
          ''
            mkdir -p "$out"
            cp -a ${py} "$out/runtime"
            chmod -R u+w "$out/runtime"
            cd "$out/runtime"

            # Build material, not runtime: python3-config (a bash script — THE
            # shell reference), the config-* dir (Makefile, install-sh,
            # makesetup), pkgconfig, nix-support plumbing, a stray darwin dev
            # script — and idle, which can never run (Tk is not shipped).
            rm -f bin/*-config bin/idle*
            rm -rf lib/python*/config-* lib/pkgconfig nix-support
            rm -f lib/python*/ctypes/macholib/fetch_macholib

            # bin/python3.x is a small launcher that links libpython3.x.so
            # through a RUNPATH pointing at the STOCK store path (CPython is
            # built --enable-shared); retarget every ELF's RUNPATH at this
            # copy BEFORE the reference strip below dummies the old hash out,
            # or the interpreter cannot resolve libpython at container start.
            find "$out/runtime" -type f | while IFS= read -r f; do
              isELF "$f" || continue
              old=$(patchelf --print-rpath "$f" 2>/dev/null) || continue
              case "$old" in
                *${py}*)
                  patchelf --set-rpath "$(printf '%s' "$old" | sed "s|${py}|$out/runtime|g")" "$f"
                  ;;
              esac
            done

            # Remaining bin/ scripts (pydoc3.x) carry shebangs pointing at the
            # stock store path; /runtime is this same tree's in-image path
            # (the images/rabbitmq.nix escript-shebang trick).
            for s in bin/*; do
              { [ -f "$s" ] && ! [ -L "$s" ]; } || continue
              head -c2 "$s" | grep -q '#!' || continue
              sed -i "1s|${py}|/runtime|" "$s"
            done

            # What remains (subprocess.py's shell=True default and its .pycs,
            # _sysconfigdata's CONFIG_ARGS) is inert build metadata:
            # same-length dummy hashes keep the files valid. shell=True now
            # fails with a clean ENOENT — correct in an image with no shell.
            find "$out/runtime" -type f -exec remove-references-to \
              -t ${py} -t ${p.bashNonInteractive} {} +
          '';
    in
    {
      contents = [ stripped ];
      entrypoint = [ "/runtime/bin/python3" ];
      cmd = [ "/app/main.py" ];
      env = [
        "PATH=/runtime/bin"
        "PYTHONDONTWRITEBYTECODE=1" # don't litter /app with .pyc on a read-only-ish rootfs
        "PYTHONUNBUFFERED=1" # flush stdout/stderr immediately for container logs
      ];
      fhs = true; # manylinux (glibc) / musllinux (musl) wheels load native .so extensions

      # SBOM: NVD files current CPython CVEs under
      # `python_software_foundation:cpython`, so the vendor=name CPE sbomnix
      # derives (python3:python3) matches nothing. Scan metadata only.
      sbomExtraComponents = [
        (vardeLib.sbomComponent {
          vendor = "python_software_foundation";
          product = "cpython";
          version = py.version;
        })
      ];
    };
in
{
  description = "Minimal distroless CPython runtime for Python apps";
  latest = "3.13"; # current default release
  variants = vardeLib.mkVariants pkgs {
    versions = {
      "3.11" = {
        spec = p: pySpec p p.python311;
      };
      "3.12" = {
        spec = p: pySpec p p.python312;
      };
      "3.13" = {
        spec = p: pySpec p p.python313;
      };
    };
  };
}
