"""Collect approved host paths from a native, root-controlled backup configuration."""

import json
import os
import re
import stat
import sys
from pathlib import Path


BACKUP_METADATA = ("backup_config.json", "backup_records.json", "backup_last_success_times.json")


def trusted(path, directory=False):
    if not path.is_absolute() or str(path) != os.path.realpath(str(path)):
        return False
    try:
        for item in (path, *path.parents):
            info = item.lstat()
            required = stat.S_ISDIR if item != path or directory else stat.S_ISREG
            if not required(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
                return False
    except OSError:
        return False
    return True


def overlaps(path, other):
    return path == other or path in other.parents or other in path.parents


def eligible(raw, forbidden):
    if not isinstance(raw, str):
        return False
    path = Path(raw)
    return (re.fullmatch(r"/[-\w./+ ]+", raw) and raw == str(path)
            and trusted(path, directory=True)
            and all(not overlaps(path, item) for item in forbidden))


def has_backup_data(path):
    if not path.is_dir():
        return False
    for entry in path.iterdir():
        # A freshly formatted ext filesystem has an empty recovery directory.
        if entry.name == "lost+found" and not entry.is_symlink() and entry.is_dir() and not any(entry.iterdir()):
            continue
        return True
    return False


def kotl_backup_source(default, candidate, config, explicit, state, protected):
    # v4 derives its effective path from VOLUME_DIR. A configured path may be
    # an active external store on other releases or a stale installation hint.
    if default != default.resolve() or (os.path.lexists(default) and not default.is_dir()):
        raise ValueError("Invalid default KOTL backup directory")
    choices = [default]
    if candidate != default:
        if trusted(config) and eligible(str(candidate), protected):
            choices.append(candidate)
        else:
            print("The configured KOTL backup path is unavailable or untrusted; checking the derived store.", file=sys.stderr)

    populated = [path for path in choices if has_backup_data(path)]
    if explicit in populated:
        return explicit
    if len(populated) == 2 and populated[0].samefile(populated[1]):
        return default
    if len(populated) > 1:
        raise ValueError("Both the derived and configured KOTL backup directories contain data. "
                         "Set JDMC_HOST_BACKUP_DIR to the existing store to use.")
    if populated:
        return populated[0]

    # An operator can identify the original disk even if the old YAML is
    # missing. An empty destination is never evidence of the original store.
    if explicit and explicit != state / "backup" and eligible(str(explicit), protected):
        if any(trusted(explicit / name) for name in BACKUP_METADATA):
            return explicit
    if candidate not in choices and candidate.is_absolute() and os.path.lexists(candidate):
        raise ValueError("The configured KOTL backup path is untrusted and no other backup store was identified")
    return choices[-1]


def main():
    store, state, node, volume, candidate, default, config = map(Path, sys.argv[1:8])
    explicit = Path(sys.argv[8]) if len(sys.argv) == 9 and sys.argv[8] else None
    permanent = [Path(item) for item in ("/etc", "/run", "/var/run", "/proc", "/sys", "/dev", "/boot", "/root",
                                         "/usr", "/lib", "/lib64", "/bin", "/sbin", "/opt/jdmc", "/opt/current",
                                         "/opt/jumpserver/config", "/var/lib/docker", "/var/lib/containerd",
                                         "/var/lib/jdmc-config", "/var/lib/jdmc-host-state")]
    protected = permanent + [node] + [state / name for name in ("config", "state", "management", "container")] + [volume / name for name in ("postgresql", "mysql", "mariadb", "redis", "openbao")]
    root = default
    kotl = default.parent != state
    if kotl:
        root = kotl_backup_source(default, candidate, config, explicit, state, protected)
    elif candidate != default:
        if trusted(config) and eligible(str(candidate), protected):
            root = candidate
        else:
            print("Custom native backup store is unavailable or untrusted. Set JDMC_HOST_BACKUP_DIR to review it.", file=sys.stderr)
    data = {}
    if kotl:
        # These files are opened by the management process after migration.
        for name in BACKUP_METADATA:
            path = root / name
            if os.path.lexists(path) and (path.is_symlink() or not path.is_file()):
                raise ValueError(f"Invalid KOTL backup metadata file: {name}")
    record = root / "backup_config.json"
    if record.exists():
        if not trusted(record):
            print("Review JDMC_HOST_BACKUP_LOG_DIRS and JDMC_HOST_BACKUP_REPLAY_DIRS: native backup configuration has untrusted ownership or permissions.", file=sys.stderr)
        elif record.stat().st_size > 8 * 1024 * 1024:
            print("Native backup configuration is too large to inspect for additional mounts. Original records are preserved.", file=sys.stderr)
        else:
            try:
                with record.open() as source:
                    data = json.load(source)
                if not isinstance(data, dict):
                    raise ValueError("expected an object")
            except (ValueError, OSError):
                if kotl:
                    raise ValueError("Invalid KOTL backup configuration; fix the original store before migration") from None
                data = {}
                print("Could not parse the native backup configuration. Original records are preserved.", file=sys.stderr)
    logs = data.get("log_directories") or []
    log_paths = [v.get("path") for v in logs if isinstance(v, dict)] if isinstance(logs, list) else []
    for label, paths in (("logs", log_paths), ("replays", [data.get("replay_directory")])):
        approved = []
        for raw in paths:
            if not raw or not isinstance(raw, str):
                continue
            raw = raw.rstrip("/")
            if eligible(raw, protected + [root, Path("/data/jdmc")]):
                if raw not in approved:
                    approved.append(raw)
            elif not str(Path(raw)).startswith(str(volume) + "/"):
                print("Review omitted native backup directory in JDMC_HOST_BACKUP_" + ("LOG_DIRS" if label == "logs" else "REPLAY_DIRS"), file=sys.stderr)
        (store / label).write_text(",".join(approved) + "\n")
    (store / "root").write_text(str(root) + "\n")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as exc:
        sys.exit(f"JDMC backup migration failed: {exc}")
