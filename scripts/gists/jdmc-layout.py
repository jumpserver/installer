"""Move the installed JDMC's persistent volumes while its writers are stopped."""

import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

OLD = {"config": "/var/lib/jdmc-config", "state": "/data/jdmc", "management": "/var/lib/jdmc-host-state"}
NEW = {name: "/data/jdmc/" + name for name in OLD}


def check(condition, message):
    if not condition:
        raise ValueError(message)


def clean_path(path):
    return path.is_absolute() and path != Path("/") and path == path.resolve()


def copy(src, dest):
    check(src.exists() and not src.is_symlink(), f"Invalid JDMC source {src}")
    dest.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    subprocess.run(["cp", "-a", "--reflink=auto", "--", str(src), str(dest)], check=True)


def config_cli(image, args, source, dest):
    check(source.is_file() and not source.is_symlink(), f"Invalid JDMC config {source}")
    temp = dest.with_name(".jdmc-relocated.yaml")
    with source.open("rb") as inp, temp.open("xb") as out:
        docker = ["docker", "run", "--rm", "-i", "--network", "none", "--read-only", "--cap-drop", "ALL",
                  "--security-opt", "no-new-privileges", "--entrypoint", "/usr/local/bin/cfgcli"]
        if args[0] == "migrate":
            docker += ["--mount", f"type=bind,source={source},target=/legacy.yaml,readonly"]
        subprocess.run([*docker, image, *args], stdin=inp, stdout=out, check=True)
    check(temp.stat().st_size, "Empty JDMC configuration")
    temp.chmod(0o600)
    # Web and host-management read their configurations as different users.
    uid = 10001 if dest.parent.name == "config" else 0
    os.chown(temp, uid, uid)
    temp.replace(dest)


def load_container(cid):
    if not cid:
        return None
    info, = json.loads(subprocess.check_output(["docker", "inspect", cid]))
    mounts = {m["Destination"]: m["Source"] for m in info["Mounts"]}
    layout = NEW if all(p in mounts for p in NEW.values()) else OLD
    check(layout["management"] in mounts, "Installer migration requires a full JDMC host-management container; basic Compose has no management volume")
    check(all(p in mounts for p in layout.values()), "JDMC container is missing persistent mounts")
    env = dict(s.split("=", 1) for s in info["Config"]["Env"] if "=" in s)
    backup_mount = "/data/jdmc/backup" if layout == NEW else env.get("JDMC_HOST_BACKUP_DIR", "/data/jdmc/backup")
    sources = {name: mounts[point] for name, point in layout.items()}
    backup = mounts.get(backup_mount)
    if not backup and layout == OLD and backup_mount.startswith("/data/jdmc/"):
        backup = str(Path(sources["state"]) / Path(backup_mount).relative_to("/data/jdmc"))
    check(backup, "Cannot identify the active JDMC backup store")
    return layout, sources, backup


def plan(target, legacy, native, backup, explicit_backup, cid):
    info = load_container(cid)
    layout, sources, old_backup = NEW, {}, backup
    check(clean_path(legacy) and clean_path(native), "Invalid old JDMC directory")
    if info:
        layout, sources, old_backup = info
    elif native == target and (target / "state").is_dir():
        sources = {n: str(target / n) for n in NEW}
    elif legacy.exists():
        layout = OLD
        sources = {n: str(legacy / ("data" if n == "state" else n)) for n in OLD}
    for src in sources.values():
        path = Path(src)
        check(clean_path(path) and path.is_dir(), f"Invalid persistent mount {src}")
    if sources:
        paths = list(map(Path, sources.values()))
        check(all(a != b and a not in b.parents and b not in a.parents
                  for i, a in enumerate(paths) for b in paths[i + 1:]), "JDMC persistent volumes overlap")
    from_kotl = not sources and native != target
    old_backup = Path(old_backup)
    check(clean_path(old_backup), f"Invalid backup source {old_backup}")
    # Configured external backup disks stay on their existing filesystem.
    # Prior defaults in a moved VOLUME_DIR follow the new root.
    defaults = {native / "backup", legacy / "backup", legacy / "data/backup"}
    if sources:
        previous = Path(sources["config"]).parent
        defaults.update((previous / "backup", Path(sources["state"]) / "backup"))
        if previous.name == "container":
            defaults.add(previous.parent / "backup")
    desired_backup = Path(explicit_backup) if explicit_backup else old_backup
    check(clean_path(desired_backup), f"Invalid backup destination {desired_backup}")
    move_backup = not explicit_backup and old_backup in defaults and old_backup != target / "backup"
    if from_kotl and old_backup.is_dir():
        same_store = desired_backup.exists() and old_backup.samefile(desired_backup)
        if explicit_backup and not same_store and any(old_backup.iterdir()):
            check(desired_backup == target / "backup",
                  f"JDMC_HOST_BACKUP_DIR differs from the KOTL backup store {old_backup}; "
                  "use the existing store or the default JDMC backup directory")
            move_backup = True
        elif move_backup and subprocess.run(["mountpoint", "-q", "--", str(old_backup)]).returncode == 0:
            # Keep a mounted KOTL backup disk in place, even at the old default path.
            move_backup = False
    if move_backup:
        desired_backup = target / "backup"
    parts = list(NEW)
    ready = layout == NEW and sources and all(Path(sources[n]) == target / n for n in NEW)
    if ready:
        parts = []
    if move_backup:
        parts.append("backup")
    if layout == NEW and sources:
        # New schema copied from a prior volume root already has fixed in-container paths.
        kind = "current"
    else:
        kind = "legacy" if sources else "native"
        if from_kotl:
            kind = "kotl"
    src = dict(sources, backup=str(old_backup))
    for name in parts:
        dest = target / name
        check(not dest.is_symlink(), f"Refusing linked JDMC destination {dest}")
        if dest.exists() and str(dest) != src.get(name):
            check(dest.is_dir() and not any(dest.iterdir()), f"JDMC destination already contains other data: {dest}")
        if name in sources and Path(sources[name]) != dest:
            check(Path(sources[name]) not in (target, *target.parents), f"Recursive JDMC source {sources[name]}")
    return dict(kind=kind, sources=sources, parts=parts, old_backup=str(old_backup),
                backup=str(desired_backup), native=str(native), cid=cid)


def migrate_native_config(stage, old, image):
    source = old / "jdmc.yaml"
    if not source.exists():
        source = old / "kotl.yaml"
    if source.exists():
        check(source.stat().st_uid == 0 and not source.is_symlink(), f"Untrusted native config {source}")
        for directory, role in (("config", "web-config"), ("management", "management-config")):
            config_cli(image, ["migrate", role, "/legacy.yaml"], source, stage / directory / "jdmc.yaml")


def stage_native(stage, old, image, *, include_license):
    for name in NEW:
        (stage / name).mkdir(mode=0o700)
    if include_license and os.path.lexists(old / "data/media/license"):
        copy(old / "data/media/license", stage / "state/license")
    for path, dest in (
        ("auth", "state/auth"), ("acheck", "state/acheck"),
        ("tls", "state/tls"), ("data/metrics", "management/data/metrics"),
        ("port_policies.json", "management/port_policies.json"), ("network", "management/network"),
        ("settings-history", "management/settings-history"), ("pending-audit", "management/pending-audit"),
    ):
        if os.path.lexists(old / path):
            copy(old / path, stage / dest)
    migrate_native_config(stage, old, image)
    subprocess.run(["chown", "-hR", "10001:10001", str(stage / "config"), str(stage / "state")], check=True)


def copy_without_backup(src, dest, exclude):
    # An old container could use the backup directory inside its data
    # volume instead of a separate bind. Do not clone archives into state.
    if src == exclude:
        return
    if src not in exclude.parents:
        copy(src, dest)
        return
    check(src.is_dir() and not src.is_symlink(), f"Invalid backup parent {src}")
    dest.mkdir()
    for item in src.iterdir():
        copy_without_backup(item, dest / item.name, exclude)
    meta = src.stat()
    os.chown(dest, meta.st_uid, meta.st_gid)
    shutil.copystat(src, dest)


def stage_data(stage, p, image):
    if p["kind"] in ("native", "kotl"):
        stage_native(stage, Path(p["native"]), image, include_license=p["kind"] == "native")
    else:
        for name in p["parts"]:
            if name in NEW:
                src = Path(p["sources"][name])
                if name == "state":
                    copy_without_backup(src, stage / name, Path(p["old_backup"]))
                else:
                    copy(src, stage / name)
        if p["kind"] == "legacy":
            state = stage / "state"
            old_license = state / "data/media/license"
            if old_license.exists():
                check(all(not d.is_symlink() for d in (state / "data", state / "data/media", old_license)),
                      "Refusing linked license directory")
                check(not os.path.lexists(state / "license"), "Conflicting license in old JDMC volume")
                old_license.rename(state / "license")
            for name, role in (("config", "web-config"), ("management", "management-config")):
                f = stage / name / "jdmc.yaml"
                if f.exists():
                    config_cli(image, ["relocate-storage", role], f, f)
    if "backup" in p["parts"]:
        source = Path(p["old_backup"])
        if source.is_dir():
            copy(source, stage / "backup")
        else:
            check(not os.path.lexists(source), f"Invalid JDMC backup source {source}")
            (stage / "backup").mkdir(mode=0o700)


def sync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def apply(target, work, image):
    pending = target / ".jdmc-layout-transition"
    if not pending.exists():
        # Copy everything before publishing the first directory. The journal
        # is on the target filesystem, so all subsequent renames are atomic.
        build = Path(tempfile.mkdtemp(prefix=".jdmc-layout-", dir=target))
        try:
            (build / "new").mkdir()
            (build / "old").mkdir()
            p = json.loads((work / "plan.json").read_text())
            stage_data(build / "new", p, image)
            (build / "plan.json").write_text(json.dumps(p))
            subprocess.run(["sync", "-f", str(build)], check=True)
            build.rename(pending)
            sync_dir(target)
        finally:
            if build.exists():
                shutil.rmtree(build)
    p = json.loads((pending / "plan.json").read_text())
    for n in p["parts"]:
        staged, dest, saved = pending / "new" / n, target / n, pending / "old" / n
        if staged.exists():
            if dest.exists():
                check(not saved.exists(), f"Unexpected JDMC destination {dest}")
                dest.rename(saved)
                sync_dir(saved.parent)
                sync_dir(target)
            staged.rename(dest)
            sync_dir(target)
            sync_dir(staged.parent)
        check(dest.is_dir() and not dest.is_symlink(), f"Missing or invalid published JDMC directory {dest}")


def commit(target, pending):
    # A process interrupted during deletion must never resume from a partially
    # deleted journal. Once renamed, all published directories are authoritative.
    completed = target / ".jdmc-layout-committed"
    if completed.exists():
        shutil.rmtree(completed)
    if pending.exists():
        pending.rename(completed)
        sync_dir(target)
        shutil.rmtree(completed)


def main():
    action, target, work, *args = sys.argv[1:]
    target, work = Path(target), Path(work)
    check(clean_path(target), f"Invalid JDMC root {target}")
    pending = target / ".jdmc-layout-transition"
    check(not pending.is_symlink(), "Invalid JDMC layout journal")
    if pending.exists():
        mode = pending.stat()
        check(mode.st_uid == 0 and stat.S_IMODE(mode.st_mode) == 0o700, "Untrusted JDMC layout journal")
    if action == "plan":
        legacy, native, backup, explicit, cid, image = args
        target.mkdir(mode=0o700, parents=True, exist_ok=True)
        root = target.stat()
        check(root.st_uid == 0 and not root.st_mode & 0o022, f"Untrusted JDMC root {target}")
        if pending.exists():
            p = json.loads((pending / "plan.json").read_text())
        else:
            p = plan(target, Path(legacy), Path(native), backup, explicit, cid)
            if p["kind"] in ("native", "kotl"):
                # Validate conversion before retiring the native writer. Apply reads
                # the source again after shutdown so the latest settings are kept.
                for name in ("config", "management"):
                    (work / name).mkdir(mode=0o700)
                migrate_native_config(work, Path(native), image)
        (work / "source-cid").write_text(p["cid"])
        (work / "new-backup").write_text(p["backup"])
        (work / "mode").write_text("move" if p["parts"] else "existing")
        (work / "plan.json").write_text(json.dumps(p))
    elif action == "apply":
        apply(target, work, args[0])
    elif action == "commit":
        commit(target, pending)
    else:
        raise ValueError(f"Unknown migration action {action}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        sys.exit(f"JDMC storage migration failed: {exc}")
