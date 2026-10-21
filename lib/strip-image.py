"""Strip ELF symbol tables out of a docker-archive image stream.

    <streamLayeredImage script> | python3 strip-image.py <llvm-strip> | pigz > image.tar.gz

nixpkgs strips only debug info (-S), so .symtab/.strtab survive in nearly
every ELF file of a closure — ~1-4 MB of gzip per image that nothing in a
container reads at runtime: the dynamic linker, dlopen/dlsym, NIF/extension
loading and C++ exception unwinding use .dynsym/.dynamic/.eh_frame, which are
allocated sections no strip mode touches. Rebuilding the packages with other
strip flags would change every store hash and lose cache.nixos.org for the
glibc variants, so this strips at image-assembly time instead, rewriting file
CONTENTS inside the layer tarballs while every store path NAME (RPATHs,
PT_INTERP, symlinks, syft's Nix cataloger) stays exactly as built.

Input is the uncompressed docker-archive streamLayeredImage writes: one
<sha256>/layer.tar per layer, then <sha256>.json (config), then manifest.json.
Each layer is spooled to disk and re-tarred member by member: every TarInfo
(name, mode, uid/gid, mtime, symlink target, …) is copied verbatim, only the
data and size of a stripped regular file change. A layer with nothing to
strip (tzdata, cacert, the customisation layer, …) is passed through byte for
byte. Layers whose bytes changed get their new sha256 as both their archive
name and their diff_id; the config is re-serialised exactly as
stream_layered_image.py writes it (json.dumps indent=4) and renamed to its new
digest, and manifest.json follows. Output is a pure function of the input
stream and the llvm-strip binary — no clocks, no randomness — so the image
stays reproducible.

What gets stripped — regular files under nix/store whose first bytes are an
ELF header:
  * ET_EXEC, and ET_DYN with a PT_INTERP and no .so name (PIE executables):
    --strip-all. .dynsym stays, so executables that export symbols to the
    plugins they dlopen (postgres, php, mysqld, beam.smp) keep working.
  * every other ET_DYN (shared libraries, .so-named or not; glibc's libc.so.6
    and ld.so carry a PT_INTERP but are libraries first): --strip-unneeded,
    which keeps anything a relocation could need.
  * ET_REL (.o, kernel modules), ET_CORE, and malformed/odd headers: skipped.
    Static archives (.a) are not ELF and never match.
--keep-section=.dep-v0 preserves cargo-auditable's embedded dependency list
(syft's Rust binary cataloger reads it). Version strings syft's binary
classifiers match, ELF package notes and Go buildinfo all live in allocated
sections (.rodata/.note.*/.go.buildinfo) that strip never removes.

A file llvm-strip rejects is shipped unmodified (and named in the log): the
image is then merely less small, never broken. llvm-strip rejecting EVERY
candidate means the stripper itself is broken, so that fails the build rather
than silently shipping unstripped images.
"""

import hashlib
import io
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile

STRIP = sys.argv[1]
TMP = tempfile.mkdtemp(prefix="varde-strip-")

ET_EXEC, ET_DYN = 2, 3
PT_INTERP = 3
# libfoo.so, libfoo.so.6, libfoo.so.6.0.1, ld-linux-x86-64.so.2,
# ld-musl-aarch64.so.1, foo.cpython-313-x86_64-linux-gnu.so
SO_NAME = re.compile(r"\.so(\.[0-9]+)*$")
COPY_BUF = 1 << 20

stats = {"candidates": 0, "stripped": 0, "failed": 0, "nogain": 0, "saved": 0}


def strip_mode(path, name):
    """llvm-strip flag for the ELF file at `path`, or None to leave it alone."""
    with open(path, "rb") as f:
        hdr = f.read(64)
        if len(hdr) < 52 or hdr[:4] != b"\x7fELF":
            return None
        ei_class, ei_data = hdr[4], hdr[5]
        if ei_class not in (1, 2) or ei_data not in (1, 2):
            return None
        end = "<" if ei_data == 1 else ">"
        (e_type,) = struct.unpack_from(end + "H", hdr, 16)
        if e_type == ET_EXEC:
            return "--strip-all"
        if e_type != ET_DYN:
            return None
        if SO_NAME.search(name):
            return "--strip-unneeded"
        # ET_DYN without a .so name: a PIE executable if it asks for an
        # interpreter, otherwise (static-pie, oddly named library) the
        # conservative mode.
        if ei_class == 2:
            if len(hdr) < 64:
                return None
            (e_phoff,) = struct.unpack_from(end + "Q", hdr, 32)
            e_phentsize, e_phnum = struct.unpack_from(end + "HH", hdr, 54)
        else:
            (e_phoff,) = struct.unpack_from(end + "I", hdr, 28)
            e_phentsize, e_phnum = struct.unpack_from(end + "HH", hdr, 42)
        for i in range(e_phnum):
            f.seek(e_phoff + i * e_phentsize)
            raw = f.read(4)
            if len(raw) < 4:
                return None
            if struct.unpack(end + "I", raw)[0] == PT_INTERP:
                return "--strip-all"
        return "--strip-unneeded"


def strip_file(src, ti, mode):
    """Strip `src` into a sibling file; return its path, or None to keep src."""
    dst = src + ".stripped"
    r = subprocess.run(
        [STRIP, mode, "--keep-section=.dep-v0", "-o", dst, src],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if r.returncode != 0 or not os.path.exists(dst):
        if os.path.exists(dst):
            os.unlink(dst)
        stats["failed"] += 1
        msg = r.stdout.decode(errors="replace").strip()
        print(f"strip-image: kept {ti.name} unmodified ({msg})", file=sys.stderr)
        return None
    new, old = os.path.getsize(dst), ti.size
    if new >= old:
        # Nothing to drop (e.g. a JNI library whose symbols are all global):
        # ship the original bytes rather than an equivalent rewrite.
        stats["nogain"] += 1
        os.unlink(dst)
        return None
    stats["stripped"] += 1
    stats["saved"] += old - new
    return dst


def rewrite_layer(src_path, dst_path):
    """Re-tar layer `src_path` into `dst_path` with ELF files stripped.

    Returns True if any file changed (otherwise dst_path is not meaningful)."""
    changed = False
    with tarfile.open(src_path, "r:") as src, tarfile.open(
        dst_path, "w:", format=tarfile.PAX_FORMAT
    ) as dst:
        for ti in src:
            data = src.extractfile(ti) if ti.isreg() else None
            if data is None or not ti.name.lstrip("/").startswith("nix/store/"):
                dst.addfile(ti, data)
                continue
            # Peek cheaply before spooling: most store files aren't ELF.
            head = data.read(4)
            data.seek(0)
            if head != b"\x7fELF":
                dst.addfile(ti, data)
                continue
            tmp = os.path.join(TMP, "f")
            with open(tmp, "wb") as f:
                shutil.copyfileobj(data, f, COPY_BUF)
            mode = strip_mode(tmp, os.path.basename(ti.name))
            stripped = None
            if mode is not None:
                stats["candidates"] += 1
                stripped = strip_file(tmp, ti, mode)
            if stripped is None:
                data.seek(0)
                dst.addfile(ti, data)
            else:
                changed = True
                ti.size = os.path.getsize(stripped)
                with open(stripped, "rb") as f:
                    dst.addfile(ti, f)
                os.unlink(stripped)
            os.unlink(tmp)
    return changed


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(COPY_BUF), b""):
            h.update(chunk)
    return h.hexdigest()


def add_bytes(out, like, name, content):
    ti = tarfile.TarInfo(name)
    ti.size = len(content)
    ti.mtime = like.mtime
    ti.mode = like.mode
    out.addfile(ti, io.BytesIO(content))


def main():
    digests = {}  # old layer sha256 -> new layer sha256
    config_names = {}  # old config archive name -> new
    with tarfile.open(fileobj=sys.stdin.buffer, mode="r|") as inp, tarfile.open(
        fileobj=sys.stdout.buffer, mode="w|", format=tarfile.PAX_FORMAT
    ) as out:
        for m in inp:
            if m.name.endswith("/layer.tar"):
                old = m.name.split("/", 1)[0]
                orig = os.path.join(TMP, "layer.orig.tar")
                new = os.path.join(TMP, "layer.new.tar")
                with open(orig, "wb") as f:
                    shutil.copyfileobj(inp.extractfile(m), f, COPY_BUF)
                path = new if rewrite_layer(orig, new) else orig
                digest = sha256_file(path) if path == new else old
                digests[old] = digest
                ti = tarfile.TarInfo(f"{digest}/layer.tar")
                ti.size = os.path.getsize(path)
                ti.mtime, ti.mode = m.mtime, m.mode
                with open(path, "rb") as f:
                    out.addfile(ti, f)
                for p in (orig, new):
                    if os.path.exists(p):
                        os.unlink(p)
            elif m.name == "manifest.json":
                manifest = json.load(inp.extractfile(m))
                for entry in manifest:
                    entry["Config"] = config_names[entry["Config"]]
                    entry["Layers"] = [
                        digests[l.split("/", 1)[0]] + "/layer.tar"
                        for l in entry["Layers"]
                    ]
                add_bytes(out, m, m.name, json.dumps(manifest, indent=4).encode())
            elif m.name.endswith(".json"):
                config = json.load(inp.extractfile(m))
                ids = config["rootfs"]["diff_ids"]
                # Layers precede the config in stream_layered_image.py's
                # output; a KeyError here means that order changed.
                config["rootfs"]["diff_ids"] = [
                    "sha256:" + digests[d.removeprefix("sha256:")] for d in ids
                ]
                content = json.dumps(config, indent=4).encode("utf-8")
                name = hashlib.sha256(content).hexdigest() + ".json"
                config_names[m.name] = name
                add_bytes(out, m, name, content)
            else:
                raise SystemExit(f"strip-image: unexpected archive member {m.name}")

    shutil.rmtree(TMP)
    print(
        "strip-image: stripped {stripped}/{candidates} ELF files ({nogain} "
        "had nothing to strip, {failed} rejected by llvm-strip), saved "
        "{mib:.1f} MiB uncompressed".format(
            mib=stats["saved"] / 2**20, **stats
        ),
        file=sys.stderr,
    )
    if stats["candidates"] and stats["failed"] == stats["candidates"]:
        raise SystemExit("strip-image: llvm-strip rejected every ELF file; is it broken?")


if __name__ == "__main__":
    main()
