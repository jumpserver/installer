#!/usr/bin/env python3
"""Build an updated const.sh from downloaded Docker/Compose binaries."""

import hashlib
from pathlib import Path
import re
import sys


def replace_once(text, pattern, replacement):
    updated, count = re.subn(pattern, lambda _: replacement, text, flags=re.MULTILINE)
    if count != 1:
        raise ValueError(f"Expected one const.sh entry matching {pattern!r}, found {count}")
    return updated


def version_from_const(text, key, requested):
    match = re.search(rf"^export {key}=(\S+)$", text, flags=re.MULTILINE)
    if match is None:
        raise ValueError(f"Missing version in const.sh: {key}")
    version = (requested or match[1]).removeprefix("v")
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:-[a-zA-Z0-9][a-zA-Z0-9.-]*)?", version):
        raise ValueError(f"Invalid version: {version!r}")
    return f"v{version}" if key == "DOCKER_COMPOSE_VERSION" else version


def checksum(path):
    digest = hashlib.sha256()
    with path.open("rb") as artifact:
        for chunk in iter(lambda: artifact.read(1024 * 1024), b""):
            digest.update(chunk)
    actual = digest.hexdigest()
    if Path(f"{path}.sha256").read_text().strip() != actual:
        raise ValueError(f"Staged checksum mismatch: {path}")
    return actual


def main():
    const_path, output_dir = map(Path, sys.argv[1:3])
    docker_input, compose_input = sys.argv[3:5]
    text = const_path.read_text()
    docker_version = version_from_const(text, "DOCKER_VERSION", docker_input)
    compose_version = version_from_const(text, "DOCKER_COMPOSE_VERSION", compose_input)

    for key, version, checksum_key in (
        ("DOCKER_VERSION", docker_version, "DOCKER_BIN_SHA256"),
        ("DOCKER_COMPOSE_VERSION", compose_version, "COMPOSE_BIN_SHA256"),
    ):
        text = replace_once(text, rf"^export {key}=\S+$", f"export {key}={version}")
        for arch in ("x86_64", "aarch64"):
            if key == "DOCKER_VERSION":
                relative_path = f"linux/static/stable/{arch}/docker-{version}.tgz"
            else:
                relative_path = f"docker/compose/releases/download/{version}/docker-compose-linux-{arch}"
            digest = checksum(output_dir / relative_path)
            text = replace_once(
                text,
                rf"^  [^:\n]+:{arch}\) {checksum_key}=[a-f0-9]+ ;;$",
                f"  {version}:{arch}) {checksum_key}={digest} ;;",
            )

    candidate = output_dir / "const.sh"
    temporary = output_dir / "const.sh.tmp"
    temporary.write_text(text)
    temporary.replace(candidate)
    print(f"Prepared {candidate}: Docker {docker_version}, Compose {compose_version}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        sys.exit(str(error))
