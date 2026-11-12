#!/usr/bin/env python3
"""Apply the pinned OpenRSAT LDAP lifetime-token patch without fetching code.

Only the exact upstream input or exact prepared output is accepted. Other
changes are never merged or overwritten. Keep editors/builds idle while running.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

UPSTREAM_COMMIT = "700177da8097717936ca0e948619723da0995452"
SOURCE = "src/net/mormot.net.ldap.pas"
SUBMODULE = "submodules/mORMot2"
PATCH_NAME = "mormot2-session-token.patch"
MANIFEST_NAME = "mormot2-session-token.json"
DEFAULT_ROOT = Path(__file__).resolve().parent.parent


class PreparationError(RuntimeError):
    pass


def canonical(data: bytes) -> bytes:
    return data.replace(b"\r\n", b"\n")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def regular_target(root: Path) -> Path:
    root = Path(os.path.abspath(root))
    if root.resolve() != root:
        raise PreparationError("Repository root must not traverse a symbolic link or junction.")
    target = root / SUBMODULE / SOURCE
    current = root
    for part in (SUBMODULE + "/" + SOURCE).split("/"):
        current /= part
        try:
            info = current.lstat()
        except FileNotFoundError as error:
            raise PreparationError(
                "Dependency source is missing; run git submodule update --init first."
            ) from error
        if stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & getattr(
            stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400
        ):
            raise PreparationError("Dependency path contains a symbolic link or reparse point.")
    if not stat.S_ISREG(target.stat().st_mode) or target.resolve() != target:
        raise PreparationError("Dependency source must be a regular in-repository file.")
    return target


def load_patch(patch_dir: Path) -> tuple[dict, bytes]:
    try:
        manifest = json.loads((patch_dir / MANIFEST_NAME).read_text(encoding="utf-8"))
        patch = canonical((patch_dir / PATCH_NAME).read_bytes())
    except (OSError, ValueError) as error:
        raise PreparationError("Cannot read dependency patch and manifest: " + str(error)) from error
    if not isinstance(manifest, dict) or manifest.get("upstream_commit") != UPSTREAM_COMMIT or manifest.get("source") != SOURCE:
        raise PreparationError("Dependency manifest does not match the supported pinned source.")
    for key in ("base_sha256_lf", "patched_sha256_lf", "patch_sha256_lf"):
        value = manifest.get(key)
        if not isinstance(value, str) or len(value) != 64 or any(c not in "0123456789abcdef" for c in value):
            raise PreparationError("Invalid dependency manifest hash: " + key)
    if digest(patch) != manifest["patch_sha256_lf"]:
        raise PreparationError("Dependency patch hash mismatch; restore the committed patch.")
    return manifest, patch


def patched_bytes(source: bytes, patch: bytes, expected_hash: str) -> bytes:
    with tempfile.TemporaryDirectory(prefix="openrsat-dependency-") as directory:
        scratch = Path(directory)
        target = scratch / SOURCE
        target.parent.mkdir(parents=True)
        target.write_bytes(canonical(source))
        # stdin avoids shell quoting and Git applies only inside this scratch tree.
        try:
            result = subprocess.run(
                ["git", "apply", "--whitespace=nowarn", "-"],
                input=patch, cwd=scratch, capture_output=True, check=False,
            )
        except OSError as error:
            raise PreparationError("Cannot run Git to prepare the dependency patch.") from error
        if result.returncode:
            raise PreparationError("Dependency patch failed in the temporary copy; source was not changed.")
        files = {p.relative_to(scratch).as_posix() for p in scratch.rglob("*") if p.is_file()}
        if files != {SOURCE} or target.is_symlink():
            raise PreparationError("Dependency patch changed unexpected paths; source was not changed.")
        prepared = canonical(target.read_bytes())
        if digest(prepared) != expected_hash:
            raise PreparationError("Prepared dependency hash mismatch; source was not changed.")
        return prepared


def prepare(root: Path, *, check: bool = False, patch_dir: Path | None = None) -> str:
    manifest, patch = load_patch(patch_dir or DEFAULT_ROOT / "patches")
    target = regular_target(root)
    original = target.read_bytes()
    current_hash = digest(canonical(original))
    if current_hash == manifest["patched_sha256_lf"]:
        return "Dependency already prepared (verified)."
    if current_hash != manifest["base_sha256_lf"]:
        raise PreparationError("Dependency source has unknown changes; leaving it untouched. Review or restore it manually.")
    if check:
        raise PreparationError("Dependency is pristine but not prepared. Run python tools/prepare_dependencies.py.")
    prepared = patched_bytes(original, patch, manifest["patched_sha256_lf"])
    # Preserve an all-CRLF checkout; canonical hashes also accept LF and mixed input.
    if b"\r\n" in original and b"\n" not in original.replace(b"\r\n", b""):
        prepared = prepared.replace(b"\n", b"\r\n")
    descriptor, name = tempfile.mkstemp(prefix=".openrsat-", suffix=".tmp", dir=target.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(prepared)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, stat.S_IMODE(target.stat().st_mode))
        # Do not replace a file changed since the initial inspection.
        if regular_target(root) != target or target.read_bytes() != original:
            raise PreparationError("Dependency changed during preparation; leaving current source untouched.")
        os.replace(temporary, target)
    finally:
        temporary.unlink(missing_ok=True)
    return "Dependency prepared and verified."


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT, help="OpenRSAT checkout root")
    parser.add_argument("--check", action="store_true", help="verify prepared dependency without writing")
    args = parser.parse_args()
    try:
        print(prepare(args.root, check=args.check))
        return 0
    except (PreparationError, OSError) as error:
        print("Dependency preparation failed: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
