# Minimal distroless CPython runtime for Python apps.
#
# Contract: drop your app at /app/main.py (override CMD for a different module).
# No shell, so the interpreter runs your script directly. These interpreters
# ship no `pip` binary (only the inert `ensurepip` stdlib module), so the base
# is already package-manager-free — install deps in a builder stage and COPY
# them in (see examples/python.Dockerfile). `fhs = true` provides an FHS glibc
# so manylinux wheels' externally-compiled .so extensions load at runtime.
{ pkgs, vardeLib, lib }:
let
  variant = py: {
    contents = [ (vardeLib.relocate pkgs "varde-python-root-${py.version}" "runtime" py) ];
    entrypoint = [ "/runtime/bin/python3" ];
    cmd = [ "/app/main.py" ];
    env = [
      "PATH=/runtime/bin"
      "PYTHONDONTWRITEBYTECODE=1" # don't litter /app with .pyc on a read-only-ish rootfs
      "PYTHONUNBUFFERED=1" # flush stdout/stderr immediately for container logs
    ];
    fhs = true; # manylinux wheels load externally-compiled native .so extensions
  };
in
{
  description = "Minimal distroless CPython runtime for Python apps";
  latest = "3.13"; # current default release
  variants = {
    "3.11" = variant pkgs.python311;
    "3.12" = variant pkgs.python312;
    "3.13" = variant pkgs.python313;
  };
}
