#!/usr/bin/env python
"""Plan, apply and resume storage migration for JDMC and its backup mounts."""
from __future__ import print_function

import errno
import filecmp
import json
import os
import re
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
from contextlib import contextmanager
from os.path import basename, dirname, exists, isabs, isdir, isfile, islink, join, lexists

DATA_DIRS = ("config", "state", "management")
SYSTEM_PATHS = ("/etc", "/run", "/var/run", "/proc", "/sys", "/dev", "/boot", "/root", "/usr", "/lib",
                "/lib64", "/bin", "/sbin", "/opt/jdmc", "/opt/current", "/opt/jumpserver/config", "/var/lib/docker",
                "/var/lib/containerd")
BACKUP_METADATA = ("backup_config.json", "backup_records.json", "backup_last_success_times.json")
NATIVE_FILES = (
    ("auth", "state/auth"), ("acheck", "state/acheck"),
    ("tls", "state/tls"), ("data/metrics", "management/data/metrics"),
    ("port_policies.json", "management/port_policies.json"), ("network", "management/network"),
    ("settings-history", "management/settings-history"), ("pending-audit", "management/pending-audit"),
)


def check(condition, message):
    if not condition:
        raise ValueError(message)


def clean_path(path):
    return isabs(path) and path != "/" and path == os.path.realpath(path)


def within(path, parent):
    return path == parent or path.startswith(parent.rstrip("/") + "/")


def overlaps(a, b):
    return within(a, b) or within(b, a)


def path_arg(raw):
    # Match the old layout's handling of trailing slashes and ".". Keep ".."
    # visible so clean_path rejects it instead of following an ambiguous path.
    return raw if ".." in raw.split("/") else os.path.normpath(raw)


def ensure_dir(path):
    try:
        os.makedirs(path, 0o700)
    except OSError as exc:
        if exc.errno != errno.EEXIST or not isdir(path):
            raise


def native_path_from_bytes(raw):
    return os.fsdecode(raw) if sys.version_info[0] >= 3 else raw


def path_bytes(value):
    if isinstance(value, bytes):
        return value
    return os.fsencode(value) if sys.version_info[0] >= 3 else value.encode("utf-8")


def read_text(path):
    with open(path, "rb") as stream:
        data = stream.read()
    return native_path_from_bytes(data)


def write_text(path, value):
    with open(path, "wb") as stream:
        stream.write(path_bytes(value))


def map_json_strings(value, convert):
    if isinstance(value, dict):
        return {convert(k): map_json_strings(v, convert) for k, v in value.items()}
    if isinstance(value, list):
        return [map_json_strings(item, convert) for item in value]
    if isinstance(value, (bytes, type(u""))):
        return convert(value)
    return value


def load_json(data):
    value = json.loads(path_bytes(data).decode("utf-8"))
    # Docker and the journal use UTF-8, even on hosts running Python under LC_ALL=C.
    return map_json_strings(value, lambda text: native_path_from_bytes(text.encode("utf-8")))


def save_plan(path, plan):
    text = map_json_strings(plan, lambda value: path_bytes(value).decode("utf-8"))
    write_text(path, json.dumps(text))


def entries(path):
    return [join(path, name) for name in os.listdir(path)]


@contextmanager
def staging_dir(target):
    path = tempfile.mkdtemp(prefix=".jdmc-layout-", dir=target)
    try:
        yield path
    finally:
        shutil.rmtree(path)


def cfgcli(image, config, args, stdout=None):
    command = ["docker", "run", "--rm", "--network", "none", "--read-only", "--cap-drop", "ALL",
               "--security-opt", "no-new-privileges", "--entrypoint", "/usr/local/bin/cfgcli",
               "--mount", "type=bind,source=%s,target=/legacy.yaml,readonly" % config, image] + args + ["/legacy.yaml"]
    with open(os.devnull, "rb") as devnull:
        if stdout is None:
            raw = subprocess.check_output(command, stdin=devnull)
            return native_path_from_bytes(raw)
        subprocess.check_call(command, stdin=devnull, stdout=stdout)


def native_config(root):
    config = join(root, "jdmc.yaml")
    return config if lexists(config) else join(root, "kotl.yaml")


def copy(src, dest, exclude=None):
    """Copy a data tree with its metadata, optionally excluding a mounted directory."""
    if src == exclude:
        return
    check(exists(src) and not islink(src), "Invalid JDMC source %s" % src)
    ensure_dir(dirname(dest))
    if exclude is None or not within(exclude, src):
        subprocess.check_call(["cp", "-a", "--reflink=auto", "--", src, dest])
        return
    os.mkdir(dest)
    for entry in entries(src):
        copy(entry, join(dest, basename(entry)), exclude)
    meta = os.stat(src)
    os.chown(dest, meta.st_uid, meta.st_gid)
    shutil.copystat(src, dest)


def convert_native_configs(image, native, stage=None):
    """Split the native YAML into the Web and management configurations."""
    src = native_config(native)
    if not lexists(src):
        return
    check(isfile(src) and not islink(src) and os.stat(src).st_uid == 0, "Invalid native config %s" % src)
    for directory, role in (("config", "web-config"), ("management", "management-config")):
        dest = join(stage, directory, "jdmc.yaml") if stage else None
        # Preflight validates the conversion; apply reads again after the native writer stops.
        if dest:
            out = os.fdopen(os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb")
        else:
            out = tempfile.TemporaryFile()
        with out:
            cfgcli(image, src, ["migrate", role], out)
            check(out.tell(), "Empty JDMC configuration")
            if dest:
                os.fchmod(out.fileno(), 0o600)
                os.fchown(out.fileno(), 0, 0)


def load_container(cid):
    if not cid:
        return None
    info, = load_json(subprocess.check_output(["docker", "inspect", cid]))
    mounts = {m["Destination"]: m["Source"] for m in info["Mounts"] if m["Type"] == "bind"}
    required = {name: "/data/jdmc/" + name for name in DATA_DIRS + ("backup",)}
    for path in required.values():
        check(path in mounts, "JDMC container is missing its persistent bind mount at %s" % path)
    env = dict(s.split("=", 1) for s in info["Config"]["Env"] if "=" in s)
    return {
        "sources": {name: mounts[required[name]] for name in DATA_DIRS},
        "backup": {"root": mounts[required["backup"]], "logs": env.get("JDMC_HOST_BACKUP_LOG_DIRS", ""),
                   "replays": env.get("JDMC_HOST_BACKUP_REPLAY_DIRS", "")},
    }


def trusted(path, directory=False):
    if not clean_path(path):
        return False
    try:
        item = path
        while True:
            info = os.lstat(item)
            required = stat.S_ISDIR if item != path or directory else stat.S_ISREG
            if not required(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
                return False
            if item == "/":
                break
            item = dirname(item)
    except OSError:
        return False
    return True


def eligible(raw, forbidden):
    # Match Unicode filenames on Python 2 as well as 3.
    try:
        text = path_bytes(raw).decode("utf-8")
    except UnicodeError:
        return False
    return (re.match(r"/[-\w./+ ]+\Z", text, re.UNICODE) and raw == path_arg(raw)
            and trusted(raw, directory=True) and not any(overlaps(raw, item) for item in forbidden))


def has_backup_data(path):
    if not isdir(path):
        return False
    for entry in entries(path):
        # A freshly formatted ext filesystem has an empty recovery directory.
        if basename(entry) == "lost+found" and not islink(entry) and isdir(entry) and not os.listdir(entry):
            continue
        return True
    return False


def has_native_files(root):
    names = ["jdmc.yaml", "kotl.yaml", "data/media/license"] + [src for src, _ in NATIVE_FILES]
    return any(lexists(join(root, name)) for name in names)


def has_container_layout(root):
    return all(isdir(join(root, part)) for part in DATA_DIRS) and not has_native_files(root)


def migration_root(target):
    kotl = join(dirname(target), "kotl")
    if not isdir(kotl) or lexists(join(target, "jdmc.yaml")):
        return target
    has_data = has_native_files(target) or isfile(join(target, "config/jdmc.yaml"))
    if has_data or any(has_backup_data(join(target, part)) for part in ("state", "management", "backup")):
        check(not has_native_files(kotl) and not has_backup_data(join(kotl, "backup")),
              "Found data in both %s and %s. Identify the active installation before migrating." % (target, kotl))
        return target
    return kotl


def native_backup_root(default, candidate, config, explicit, state, protected):
    choices = [default]
    if candidate != default:
        if trusted(config) and eligible(candidate, protected):
            choices.append(candidate)
        else:
            print("Configured backup store is unavailable or untrusted; checking the default.", file=sys.stderr)
    # The live store may have been derived from VOLUME_DIR despite a different YAML value.
    check(clean_path(default) and (not lexists(default) or isdir(default)),
          "Invalid default backup directory %s" % default)
    populated = [path for path in choices if has_backup_data(path)]
    if explicit in populated:
        return explicit
    if len(populated) == 2 and os.path.samefile(populated[0], populated[1]):
        return default
    if len(populated) > 1:
        raise ValueError("Both the derived and configured backup directories contain data. "
                         "Set JDMC_HOST_BACKUP_DIR to the existing store to use.")
    if populated:
        return populated[0]

    # An operator can identify the original disk even if the old YAML is
    # missing. An empty destination is never evidence of the original store.
    if (explicit and explicit != join(state, "backup") and eligible(explicit, protected)
            and any(trusted(join(explicit, name)) for name in BACKUP_METADATA)):
        return explicit
    if candidate not in choices and isabs(candidate) and lexists(candidate):
        raise ValueError("The configured backup path is untrusted and no other backup store was identified")
    return choices[-1]


def native_backup_mounts(state, native, node, volume, explicit, image):
    default = join(native, "backup")
    config = native_config(native)
    candidate = default
    if isfile(config) and not islink(config) and os.stat(config).st_uid == 0:
        configured = cfgcli(image, config, ["get", "backup-path"])
        candidate = path_arg(configured.rstrip("\n") or default)
    protected = list(SYSTEM_PATHS)
    protected += [node] + [join(state, name) for name in DATA_DIRS]
    protected += [join(volume, name) for name in ("postgresql", "mysql", "mariadb", "redis", "openbao")]
    root = native_backup_root(default, candidate, config, explicit, state, protected)
    kotl = native != state
    record = join(root, "backup_config.json")
    if kotl:
        for name in BACKUP_METADATA:
            path = join(root, name)
            check(not lexists(path) or (isfile(path) and not islink(path)),
                  "Invalid KOTL backup metadata file: %s" % name)
    data = {}
    if exists(record):
        if trusted(record) and os.stat(record).st_size <= 8 * 1024 * 1024:
            try:
                data = load_json(read_text(record))
                check(isinstance(data, dict), "expected a backup configuration object")
            except (ValueError, OSError, IOError):
                if kotl:
                    raise ValueError("Invalid KOTL backup configuration; fix the original store before migration")
                data = {}
                print("Could not parse native backup configuration; original records are preserved.", file=sys.stderr)
        else:
            print("Review native backup configuration permissions and size before adding its host mounts.", file=sys.stderr)
    logs = data.get("log_directories") or []
    log_paths = [v.get("path") for v in logs if isinstance(v, dict)] if isinstance(logs, list) else []
    mounts = {"root": root}
    for label, paths in (("logs", log_paths), ("replays", [data.get("replay_directory")])):
        approved = []
        for raw in paths:
            if not raw or not isinstance(raw, str):
                continue
            raw = raw.rstrip("/")
            if raw in approved:
                continue
            if eligible(raw, protected + [root, "/data/jdmc"]):
                approved.append(raw)
            elif not path_arg(raw).startswith(volume + "/"):
                print("Review omitted native backup directory in JDMC_HOST_BACKUP_" + ("LOG_DIRS" if label == "logs" else "REPLAY_DIRS"), file=sys.stderr)
        mounts[label] = ",".join(approved)
    # Older native backups could be 0755. Never chmod an arbitrary external parent.
    if isdir(root) and clean_path(root) and (root == default or isfile(record)):
        st = os.stat(root)
        if st.st_uid == st.st_gid == 0:
            os.chmod(root, 0o700)
    return mounts


def backup_inputs(target, native, node, volume, explicit, image, cid, work, pending):
    store = join(node, "backup-mounts")
    check(not islink(store), "Invalid JDMC backup mount directory %s" % store)
    published = islink(join(node, "release"))
    fields = [join(store, name) for name in ("root", "logs", "replays")]
    if all(isfile(f) and not islink(f) for f in fields):
        saved = read_text(fields[0]).rstrip("\n")
        # Until migration starts, rediscover the live backup store on each preflight.
        if saved and (published or pending or cid or (native == target and has_container_layout(target))):
            return (None if pending else load_container(cid)), saved
    check(cid or not (published or pending), "Restore %s or the previous container to identify its backup mounts" % store)
    container = load_container(cid)
    mounts = container["backup"] if container else native_backup_mounts(target, native, node, volume, explicit, image)
    stage = join(work, "backup-mounts")
    os.mkdir(stage, 0o700)
    for field, value in mounts.items():
        write_text(join(stage, field), value + "\n")
    if exists(store):
        for field in ("logs", "replays", "root"):
            os.rename(join(stage, field), join(store, field))
    else:
        os.rename(stage, store)
    return container, mounts["root"]


def storage_sources(target, native, info, published):
    if info:
        return "current", info["sources"]
    if published and isdir(join(target, "state")):
        return "current", {name: join(target, name) for name in DATA_DIRS}
    if published:
        raise ValueError("Cannot locate published JDMC storage; restore the previous VOLUME_DIR or container")
    if native != target:
        return "kotl", {}
    # Existing directories can be reused only if there is no native data to migrate.
    if has_container_layout(target):
        return "current", {name: join(target, name) for name in DATA_DIRS}
    return "native", {}


def plan(target, native, backup, explicit_backup, cid, info, published):
    check(clean_path(native), "Invalid native data directory %s" % native)
    kind, sources = storage_sources(target, native, info, published)
    paths = list(sources.values())
    for path in paths:
        check(clean_path(path) and isdir(path), "Invalid persistent mount %s" % path)
    check(all(not overlaps(a, b)
              for i, a in enumerate(paths) for b in paths[i + 1:]), "JDMC persistent volumes overlap")
    old_backup = path_arg(info["backup"]["root"] if info else backup)
    check(clean_path(old_backup), "Invalid backup source %s" % old_backup)
    # Configured external backup disks stay on their existing filesystem.
    # Prior defaults in a moved VOLUME_DIR follow the new root.
    defaults = {join(native, "backup")}
    if sources:
        defaults.add(join(dirname(sources["config"]), "backup"))
    desired_backup = path_arg(explicit_backup) if explicit_backup else old_backup
    check(clean_path(desired_backup), "Invalid backup destination %s" % desired_backup)
    move_backup = not explicit_backup and old_backup in defaults and old_backup != join(target, "backup")
    if kind in ("kotl", "native") and isdir(old_backup):
        same_store = exists(desired_backup) and os.path.samefile(old_backup, desired_backup)
        if explicit_backup and not same_store and has_backup_data(old_backup):
            check(desired_backup == join(target, "backup"),
                  "JDMC_HOST_BACKUP_DIR differs from the existing backup store %s; "
                  "use the existing store or the default JDMC backup directory" % old_backup)
            move_backup = True
        elif move_backup and subprocess.call(["mountpoint", "-q", "--", old_backup]) == 0:
            # Keep a mounted backup disk in place, even at the old default path.
            move_backup = False
    parts = list(DATA_DIRS)
    if kind == "current":
        parts = [name for name in DATA_DIRS if sources[name] != join(target, name)]
    if move_backup:
        desired_backup = join(target, "backup")
        parts.append("backup")
    src = dict(sources, backup=old_backup)
    for name in parts:
        dest = join(target, name)
        check(not islink(dest), "Refusing linked JDMC destination %s" % dest)
        if exists(dest) and dest != src.get(name):
            # The installer prepares the shared credentials before any data migration.
            allowed = {"core"} if name == "config" else set()
            check(isdir(dest) and all(basename(f) in allowed and isdir(f) and not islink(f) for f in entries(dest)),
                  "JDMC destination already contains other data: %s" % dest)
        if name in sources and sources[name] != dest:
            check(not within(target, sources[name]), "Recursive JDMC source %s" % sources[name])
    return dict(kind=kind, sources=sources, parts=parts, old_backup=old_backup,
                backup=desired_backup, native=native, cid=cid)


def stage_data(stage, p, image, target):
    kind, backup = p["kind"], p["old_backup"]
    if kind in ("native", "kotl"):
        native = p["native"]
        for name in DATA_DIRS:
            os.mkdir(join(stage, name), 0o700)
        files = list(NATIVE_FILES)
        if kind == "native":
            files.append(("data/media/license", "state/license"))
        for src, dest in files:
            if lexists(join(native, src)):
                copy(join(native, src), join(stage, dest))
        convert_native_configs(image, native, stage)
        subprocess.check_call(["chown", "-hR", "0:0", join(stage, "config"), join(stage, "state")])
    else:
        for name in DATA_DIRS:
            if name in p["parts"]:
                src = p["sources"][name]
                if name == "config" and isdir(join(src, "core")):
                    core = join(src, "core")
                    target_core = join(target, "config/core")
                    for file in ("node-name", "enrollment-secret", "callback-ca.crt"):
                        original, current = join(core, file), join(target_core, file)
                        if exists(original):
                            check(isfile(current) and filecmp.cmp(original, current, shallow=False),
                                  "Restore the existing JDMC node identity before migrating %s" % src)
                    copy(src, join(stage, name), core)
                else:
                    copy(src, join(stage, name))
    if "backup" in p["parts"]:
        if isdir(backup):
            copy(backup, join(stage, "backup"))
        else:
            check(not lexists(backup), "Invalid JDMC backup source %s" % backup)
            os.mkdir(join(stage, "backup"), 0o700)


def sync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def publish_directory(source, dest):
    os.rename(source, dest)
    sync_dir(dirname(dest))
    if dirname(source) != dirname(dest):
        sync_dir(dirname(source))


def apply(target, work, image, live):
    p = load_json(read_text(join(work, "plan.json")))
    if not p["parts"]:
        return
    if live and p["cid"] == live:
        subprocess.check_call(["docker", "stop", live], stdout=sys.stderr)
    pending = join(target, ".jdmc-layout-transition")
    if not exists(pending):
        # Copy everything before publishing the first directory. The journal
        # is on the target filesystem, so all subsequent renames are atomic.
        with staging_dir(target) as tmp:
            build = join(tmp, "journal")
            os.mkdir(build, 0o700)
            os.mkdir(join(build, "new"))
            os.mkdir(join(build, "old"))
            stage_data(join(build, "new"), p, image, target)
            shutil.copyfile(join(work, "plan.json"), join(build, "plan.json"))
            subprocess.check_call(["sync", "-f", build])
            publish_directory(build, pending)
    for n in p["parts"]:
        staged, dest, saved = join(pending, "new", n), join(target, n), join(pending, "old", n)
        if n == "config" and isdir(staged) and isdir(join(dest, "core")):
            # Keep the mounted credentials directory in place throughout the cutover.
            for entry in entries(staged):
                check(not lexists(join(dest, basename(entry))), "Conflicting JDMC config: %s" % basename(entry))
                publish_directory(entry, join(dest, basename(entry)))
            os.rmdir(staged)
        elif exists(staged):
            # Compose can recreate the empty backup bind directory before a retry.
            # rename replaces it atomically and refuses non-empty directories and mount points.
            if n != "backup" and exists(dest):
                check(not exists(saved), "Unexpected JDMC destination %s" % dest)
                publish_directory(dest, saved)
            publish_directory(staged, dest)
        check(isdir(dest) and not islink(dest), "Missing or invalid published JDMC directory %s" % dest)


def commit(target, work, node):
    p = load_json(read_text(join(work, "plan.json")))
    saved = join(node, "backup-mounts/root")
    if read_text(saved).rstrip("\n") != p["backup"]:
        staged = join(work, "backup-root")
        write_text(staged, p["backup"] + "\n")
        os.rename(staged, saved)
    pending = join(target, ".jdmc-layout-transition")
    # A process interrupted during deletion must never resume from a partially
    # deleted journal. Once renamed, all published directories are authoritative.
    completed = join(target, ".jdmc-layout-committed")
    if exists(completed):
        shutil.rmtree(completed)
    if exists(pending):
        publish_directory(pending, completed)
        shutil.rmtree(completed)


def callback_available(volume, host):
    volume = path_arg(volume)
    try:
        if host != "host-gateway":
            if "%" in host:
                return False
            socket.inet_pton(socket.AF_INET6 if ":" in host else socket.AF_INET, host)
        root = join(dirname(volume), "jdmc/config/core")
        return (volume == os.path.realpath(volume) and isdir(volume)
                and trusted(root, directory=True) and all(trusted(path) for path in entries(root)))
    except (socket.error, OSError, ValueError):
        return False


def main():
    if sys.argv[1:2] == ["check-callback"]:
        sys.exit(0 if len(sys.argv) == 4 and callback_available(*sys.argv[2:]) else 1)
    action, target, work = sys.argv[1:4]
    args = sys.argv[4:]
    target, work = path_arg(target), path_arg(work)
    check(clean_path(target), "Invalid JDMC root %s" % target)
    pending = join(target, ".jdmc-layout-transition")
    check(not islink(pending), "Invalid JDMC layout journal")
    if exists(pending):
        mode = os.stat(pending)
        check(mode.st_uid == 0 and stat.S_IMODE(mode.st_mode) == 0o700, "Untrusted JDMC layout journal")
    if action == "plan":
        node, volume = map(path_arg, args[:2])
        explicit, cid, image = args[2:]
        published = islink(join(node, "release"))
        native = target if cid or published or exists(pending) else migration_root(target)
        explicit = path_arg(explicit) if explicit else None
        ensure_dir(target)
        root = os.stat(target)
        check(root.st_uid == 0 and not root.st_mode & 0o022, "Untrusted JDMC root %s" % target)
        container, backup = backup_inputs(target, native, node, volume, explicit, image, cid, work, exists(pending))
        if exists(pending):
            p = load_json(read_text(join(pending, "plan.json")))
            check(p["kind"] in ("native", "kotl", "current"), "Unsupported JDMC migration journal")
        else:
            p = plan(target, native, backup, explicit, cid, container, published)
            if p["kind"] in ("native", "kotl"):
                # Validate conversion before retiring the native writer. Apply reads
                # the source again after shutdown so the latest settings are kept.
                convert_native_configs(image, native)
        save_plan(join(work, "plan.json"), p)
        getattr(sys.stdout, "buffer", sys.stdout).write(path_bytes(p["backup"] + "\n"))
    elif action == "apply":
        apply(target, work, *args)
    elif action == "commit":
        commit(target, work, path_arg(args[0]))
    else:
        raise ValueError("Unknown migration action %s" % action)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, IOError, subprocess.CalledProcessError) as exc:
        sys.exit("JDMC storage migration failed: %s" % exc)
