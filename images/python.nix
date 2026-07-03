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
{ pkgs, vardeLib, lib }:
let
  # `p` is the libc's package set (pkgs for glibc, pkgs.pkgsMusl for musl).
  pySpec = p: py: {
    contents = [ (vardeLib.relocate p "varde-python-root-${py.version}" "runtime" py) ];
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
      "3.11" = { spec = p: pySpec p p.python311; };
      "3.12" = { spec = p: pySpec p p.python312; };
      "3.13" = { spec = p: pySpec p p.python313; };
    };
  };
}
