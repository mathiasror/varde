# varde-python example: a third-party dependency installed the "built-in
# tooling" way — pip + requirements.txt — but resolved in a *builder* stage and
# copied in, because the varde-python runtime has no pip of its own.
#
# python-dateutil is pure Python, so the import below works identically on the
# musl (default) and glibc runtimes.
from dateutil import tz


def main() -> None:
    # Touch the dependency so a missing/broken install fails loudly at runtime
    # rather than silently printing "ok". tz.tzutc() needs no data files.
    _utc = tz.tzutc()
    assert _utc is not None

    # The e2e smoke test greps stdout for the exact string "varde ok".
    print("varde ok")


if __name__ == "__main__":
    main()
