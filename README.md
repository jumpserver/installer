<div align="center">

# JumpServer Installer

Deploy and manage [JumpServer](https://www.jumpserver.com/) with Docker Compose.

[![Release](https://img.shields.io/github/v/release/jumpserver/installer?label=release)](https://github.com/jumpserver/installer/releases)
[![License](https://img.shields.io/badge/license-GPLv3-blue.svg)](LICENSE)
[![Docs](https://img.shields.io/badge/docs-jumpserver.com-2f6feb.svg)](https://www.jumpserver.com/docs)
[![Quality](https://github.com/jumpserver/installer/actions/workflows/quality.yml/badge.svg)](https://github.com/jumpserver/installer/actions/workflows/quality.yml)

[English](README.md) · [简体中文](readmes/README.zh-hans.md) · [繁體中文](readmes/README.zh-hant.md)

</div>

## Overview

JumpServer is an open-source Privileged Access Management (PAM) platform and bastion host. It provides audited, role-based access to SSH, RDP, Kubernetes, databases, websites, RemoteApp, and VirtualApp assets.

This repository contains the official installer. It prepares the host, installs Docker and Docker Compose when needed, renders the Compose stack, loads images, migrates the database schema, and manages the deployment through `jmsctl.sh`.

- Application source: [jumpserver/jumpserver](https://github.com/jumpserver/jumpserver)
- Documentation: [jumpserver.com/docs](https://www.jumpserver.com/docs)
- Configuration reference: [environment variables](https://docs.jumpserver.org/zh/v3/guide/env/)

## Table of contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Ports](#ports)
- [Management commands](#management-commands)
- [Configuration](#configuration)
- [Upgrade](#upgrade)
- [Offline installation](#offline-installation)
- [Enterprise edition (JDMC)](#enterprise-edition-jdmc)
- [SSH Ansible executor](#ssh-ansible-executor)
- [Repository layout](#repository-layout)
- [Development](#development)
- [Community](#community)
- [License](#license)

## Requirements

| Item | Requirement |
| --- | --- |
| Operating system | Linux with systemd |
| Architecture | `x86_64` or `aarch64` |
| Kernel | 4.0 or later |
| Privileges | `root` or a user with `sudo` |
| Resources | 4 vCPU, 8 GiB RAM, and 100 GiB disk as a starting point for a small production deployment |
| Network | Access to an image registry, or an offline image package |
| Time | NTP synchronization is recommended |

`./jmsctl.sh install` installs Docker 29.10.1 and Docker Compose v2.40.3 when they are missing. On hosts that cannot use systemd, install Docker and the Compose plugin before running the installer and set `UNCHECK_DEPENDENCIES=1`.

## Quick start

### Install from a release archive (recommended)

```bash
# Replace vX.Y.Z with the latest tag from https://github.com/jumpserver/installer/releases
VERSION=vX.Y.Z
curl -fLO "https://github.com/jumpserver/installer/releases/download/${VERSION}/jumpserver-installer-${VERSION}.tar.gz"
curl -fLO "https://github.com/jumpserver/installer/releases/download/${VERSION}/jumpserver-installer-${VERSION}.tar.gz.sha256"
sha256sum -c "jumpserver-installer-${VERSION}.tar.gz.sha256"
tar -xzf "jumpserver-installer-${VERSION}.tar.gz"
cd "jumpserver-installer-${VERSION}"

sudo ./jmsctl.sh install
sudo ./jmsctl.sh start
```

`install` performs first-time setup:

1. Installs and configures Docker and Docker Compose when missing.
2. Collects settings and writes `/opt/jumpserver/config/config.txt`.
3. Loads images and initializes or migrates the database schema.
4. Installs JDMC on the enterprise edition.

After `start`, open `http://<host>/`, or the HTTPS URL when TLS is configured. The default username is `admin`. The initial password is printed at the end of the installation; change it after the first login.

### Install from source

```bash
git clone https://github.com/jumpserver/installer.git
cd installer
git checkout <tag>

sudo ./jmsctl.sh install
sudo ./jmsctl.sh start
```

> [!NOTE]
> On offline hosts, prepare the image package described in [Offline installation](#offline-installation) before running `install`.

## Ports

| Port | Default | Service | Notes |
| --- | --- | --- | --- |
| `80` | HTTP | Web console and API | Set `HTTP_PORT=0` to disable |
| `443` | HTTPS | Web console and API | Used when `HTTPS_PORT` and certificates are configured |
| `2222` | TCP | KoKo SSH | SSH and SFTP sessions to assets |
| `5001` | TCP | KoKo web proxy | Published on the host; restrict it with `WEB_PROXY_ALLOWED_HOSTS` |
| `3389` | TCP | Razor RDP | Enterprise edition |
| `3390` | TCP | XRDP | Enterprise edition; disabled by default |
| `5525` | TCP | Magnus | Enterprise edition database proxy |
| `15900` | TCP | NEC | Enterprise edition VNC |

The Docker networks `DOCKER_SUBNET` (default `192.168.250.0/24`) and `DOCKER_EXECUTOR_SUBNET` (default `192.168.252.0/24`) must not overlap the host, asset, VPN, or other Docker networks.

## Management commands

Run `sudo ./jmsctl.sh <command>` from the installer directory. `--skip-jdmc` on `start`, `stop`, `restart`, `status`, and `down` only prevents a JDMC-initiated restart from stopping JDMC itself; it is not a component switch.

| Command | Description |
| --- | --- |
| `install` | First-time installation: configure Docker, write configuration, load images, initialize the database, and install JDMC on the enterprise edition |
| `upgrade [version]` | Upgrade to the given version, or to the version bundled with the installer |
| `check_update` | Check whether a newer release is available |
| `config [ntp\|init\|port\|ssl\|env]` | Adjust NTP, configuration, service ports, TLS, or environment settings |
| `start` | Start all enabled services |
| `stop [service]` | Stop and remove containers; data in `VOLUME_DIR` is kept |
| `restart [service]` | Restart all services or one service |
| `status` | Show container status, and JDMC status on the enterprise edition |
| `close [service]` | Stop application containers but leave database containers running |
| `down [service]` | Stop and remove all containers, or one service |
| `prepare [service ...]` | Prepare directories, permissions, and keys without starting services |
| `prepare --containers <name ...>` | Prepare stopped containers using their installed images |
| `load_image` | Load images from the offline image directory |
| `backup_db` | Back up the database |
| `backup_no_audit` | Back up the database without audit tables |
| `backup_audit` | Back up only audit tables |
| `restore_db [file]` | Restore the database from a backup file |
| `tail [service]` | Follow logs for all services or one service |
| `raw <compose args...>` | Run the generated `docker compose` command directly |
| `video-worker <start\|stop\|restart\|status>` | Manage the enterprise video worker |
| `uninstall` | Remove containers, networks, and optionally files, images, and Docker binaries; prompts before destructive steps |
| `version` | Show the installed version |

Run `./jmsctl.sh --help` for the full command summary.

## Configuration

Configuration is stored in `/opt/jumpserver/config` after installation:

```text
/opt/jumpserver/config/
├── config.txt          # main configuration, mounted into containers
├── nginx/
│   ├── cert/
│   │   ├── server.crt
│   │   └── server.key
│   ├── lb_http_server.conf
│   └── lb_ssh_server.conf
├── mysql/
│   └── my.cnf
├── mariadb/
│   └── mariadb.cnf
└── redis/
    └── redis.conf
```

`config.txt` is an environment file shared by all containers, so KoKo, Core, and other components do not need separate configuration files. The installer also generates a restricted `config_safe.txt` for components that should not receive every value. See `config-example.txt` for the annotated reference.

### Common settings

| Setting | Default | Purpose |
| --- | --- | --- |
| `VOLUME_DIR` | `/data/jumpserver` | Persistent data, recordings, task logs, and backups |
| `SECRET_KEY`, `BOOTSTRAP_TOKEN` | generated | Secrets that must be preserved when migrating an environment |
| `HTTP_PORT`, `HTTPS_PORT` | `80`, `443` | Web ports; set a port to `0` to disable it |
| `SERVER_NAME`, `SSL_CERTIFICATE`, `SSL_CERTIFICATE_KEY` | empty | Enable HTTPS |
| `DB_ENGINE` | `postgresql` | Built-in database engine |
| `DB_HOST` | `postgresql` | `postgresql` or `mysql` for a built-in database, or an external host |
| `DB_IMAGE` | version-dependent | Override the built-in database image, for example `mysql:8.0` |
| `REDIS_HOST`, `REDIS_PORT`, `REDIS_PASSWORD` | `redis`, `6379` | Built-in Redis connection |
| `DOCKER_SUBNET`, `DOCKER_EXECUTOR_SUBNET` | `192.168.250.0/24`, `192.168.252.0/24` | Container networks |
| `TZ` | `Asia/Shanghai` | Container time zone |
| `IMAGE_PULL_PREFIX`, `NAMESPACE`, `IMAGE_PULL_SCOPE`, `IMAGE_PULL_POLICY` | empty, `jumpserver`, `jumpserver`, `Always` | Image source and local naming |
| `USE_XPACK` | `0` | Deploy enterprise components such as JDMC |
| `KOKO_SSH_PORT`, `RAZOR_RDP_PORT`, `MAGNUS_PORT`, `NEC_VNC_PORT` | `2222`, `3389`, `5525`, `15900` | Component ports |
| `ANSIBLE_EXECUTOR_*`, `CELERY_PRIVILEGED` | built-in defaults | Executor deployment and Celery isolation |
| `*_ENABLED` | `1` | Disable an individual service with `0` |

### Built-in database

New installations use PostgreSQL 18.7. To use built-in MySQL 8.0, set `DB_ENGINE=mysql`, `DB_HOST=mysql`, and `DB_IMAGE=mysql:8.0`; the interactive installer also asks for the built-in database image. When `DB_IMAGE` is unset, new installations use MariaDB 10.6.

An existing `VOLUME_DIR/mysql/data` or `VOLUME_DIR/mariadb/data` determines which database keeps being used. Changing `DB_IMAGE` does not migrate existing data. Offline installations must provide the selected database image.

## Upgrade

```bash
sudo ./jmsctl.sh upgrade
```

Online upgrades pull the required images. Offline upgrades load them from the local image package. Before upgrading, back up the environment and keep `VOLUME_DIR`, `SECRET_KEY`, and `BOOTSTRAP_TOKEN`.

Starting with v5.3.0, KoKo hosts Chen, Kael and Lion. Before upgrading, finish active Chen sessions and let the old service upload pending audits and recordings. Starting or restarting KoKo stops the old standalone containers and disables their automatic restart. When stopping the deployment or KoKo, the installer stops these containers directly through Docker before loading the Compose configuration. You can also stop one by name, for example `jmsctl stop chen`, even when Compose is unavailable. An upgrade also stops them before database migration. After a successful upgrade, it removes these containers and keeps their mounted data. KoKo reuses `${VOLUME_DIR}/kael/data` and stores new Chen state under `${VOLUME_DIR}/koko/data/chen` by default. The old Chen data directory is retained. On nodes that previously ran only Chen, Kael or Lion, enable KoKo to host those features locally. The integrated workbench follows `KOKO_ENABLED`. The old `CHEN_ENABLED=0` setting applied to the standalone service.

### Database backup during upgrade

When an external MySQL or PostgreSQL database is used without `HA_MODE=1`, a missing, unloadable, or unpullable backup client image only produces a warning, and the upgrade continues to the backup step. If no usable client image exists locally, the backup is skipped; if an image is available, the installer attempts the backup normally. Built-in databases and required application images must still be prepared successfully.

If every database backup attempt fails, the installer prompts:

```text
Failed to backup the database. Continue to upgrade? [Y/n] (Timeout: 30s, default: y):
```

Enter `y` (case-insensitive) or press Enter to continue, or `n` to abort. After 30 seconds without input, the prompt times out and continues. Any other input, or a closed input stream, aborts the upgrade. This timeout applies only to this backup-failure confirmation; other confirmations keep their existing behavior. `AUTO_INSTALL=1` takes the default `y` under the existing unattended rules.

Continuing means accepting that this installer did not produce a successful database backup; make sure a DBA or cloud database provides a recoverable backup.

To skip the backup and backup-client image preparation explicitly:

```bash
SKIP_BACKUP_DB=1 ./jmsctl.sh upgrade
```

Schema migration is still performed by Core against the database. A standalone `backup_db` failure still returns a non-zero status and does not trigger the upgrade prompt. This flow does not change backup client versions, so a backup may still fail when the PostgreSQL client and server versions are incompatible. `SKIP_BACKUP_DB` is passed through the command environment, not set in `config.txt`.

Built-in PostgreSQL versions 10 through 17 are migrated to PostgreSQL 18 during the same maintenance window. See [PostgreSQL 18 migration](docs/postgresql-18-upgrade.md) for the migration flow, disk requirements, custom configurations, and JDMC HA coordination.

The installer no longer creates a symlink from `/opt/jumpserver/data` to the host data directory on install or upgrade; existing links, directories, and backups stay as they are. Other symlinks used by configuration files, historical data migration, and current installer paths are preserved.

## Offline installation

An offline installation loads images from `scripts/images/` instead of pulling them from a registry. The directory must contain each image as a `.zst` archive plus a `.sha256` file holding the expected image ID.

```bash
# Copy the packaged images into the installer directory, then:
sudo ./jmsctl.sh install
sudo ./jmsctl.sh load_image
```

`install` and `upgrade` detect the image package automatically; `load_image` loads it explicitly. See [Offline installation](docs/offline-installation.md) for the file layout, image manifest, and registry-prefix settings.

## Enterprise edition (JDMC)

JDMC is an enterprise-edition component enabled with `USE_XPACK=1`. It runs as a host systemd service and is not part of the Docker Compose stack. The community edition neither downloads nor installs JDMC; the enterprise edition always installs it.

See [Enterprise edition: JDMC](docs/jdmc.md) for image handling, HA host dependencies, data paths, migration from KOTL, service preparation, and the video worker.

## SSH Ansible executor

The installer deploys `jumpserver/ansible-executor` for CE and EE. Core and Celery reuse the `ANSIBLE_DOCKER_ENABLED` switch: enabled uses the persistent executor over SSH, disabled executes locally.

The executor listens on 2222 inside a dedicated `executor` network, publishes no host port, and mounts neither Core data nor the Docker socket. Per-installation keys are generated on first start and kept across restarts and upgrades; back up `${CONFIG_DIR}/ansible-executor`.

See [SSH Ansible executor](docs/ansible-executor.md) for networking, isolation, resource limits, external executors, and the `CELERY_PRIVILEGED` trade-off.

## Repository layout

| Path | Contents |
| --- | --- |
| `jmsctl.sh` | Command-line entry point |
| `scripts/` | Numbered install, upgrade, backup, and uninstall steps plus shared helpers |
| `scripts/gists/` | Image, service, database, and PostgreSQL migration helpers |
| `compose/` | Per-service Docker Compose fragments |
| `config-example.txt` | Annotated reference configuration |
| `config_init/` | Initial configuration templates for MySQL, MariaDB, Redis, OpenBao, Loki, and the executor |
| `locale/` | CLI translations for `en`, `zh_CN`, and `zh_Hant` |
| `tests/` | Bash regression tests |
| `docs/` | Topic guides in English, Simplified Chinese, and Traditional Chinese |
| `.github/workflows/` | Quality checks, OSS mirror synchronization, and release drafting |

## Development

Run the shell syntax check and the regression suite before submitting changes:

```bash
find . -type f -name '*.sh' -print0 | while IFS= read -r -d '' file; do
  bash -n "${file}"
done

bash tests/run.sh
```

Maintainer notes for the Docker and Compose binary mirror are in [Docker and Compose mirror synchronization](docs/docker-mirror.md).

## Community

- Documentation: <https://www.jumpserver.com/docs>
- Releases: <https://github.com/jumpserver/installer/releases>
- Issues: <https://github.com/jumpserver/jumpserver/issues>
- Discord: <https://discord.gg/jumpserver>

## License

This project is licensed under the GNU General Public License version 3 (GPLv3), matching [JumpServer](https://github.com/jumpserver/jumpserver). See [LICENSE](LICENSE) for the full terms.
