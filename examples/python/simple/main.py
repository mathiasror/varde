# Minimal varde-python example: no dependencies at all.
#
# The varde-python base is *just* the CPython interpreter:
#   ENTRYPOINT ["/runtime/bin/python3"]   CMD ["/app/main.py"]
# so the container literally runs `python3 /app/main.py`. There is no shell and
# no pip in the image — nothing to install, nothing to invoke but the script.


def main() -> None:
    # The e2e smoke test greps stdout for the exact string "varde ok".
    print("varde ok")


if __name__ == "__main__":
    main()
