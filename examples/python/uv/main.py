# varde-python example: the modern uv workflow.
#
# Dependencies are declared in pyproject.toml and pinned in uv.lock. The
# Dockerfile exports that lock to a requirements file and installs it into a
# plain directory that gets copied into the distroless runtime — the final
# image never sees uv or pip.
from dateutil import tz


def main() -> None:
    # Exercise the dependency so a broken install fails loudly here.
    _utc = tz.tzutc()
    assert _utc is not None

    # The e2e smoke test greps stdout for the exact string "varde ok".
    print("varde ok")


if __name__ == "__main__":
    main()
