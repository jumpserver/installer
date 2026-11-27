<div align="center">

# JumpServer Installer

使用 Docker Compose 部署和管理 [JumpServer](https://www.jumpserver.com/)。

[![Release](https://img.shields.io/github/v/release/jumpserver/installer?label=release)](https://github.com/jumpserver/installer/releases)
[![License](https://img.shields.io/badge/license-GPLv3-blue.svg)](../LICENSE)
[![Docs](https://img.shields.io/badge/docs-jumpserver.com-2f6feb.svg)](https://www.jumpserver.com/docs)
[![Quality](https://github.com/jumpserver/installer/actions/workflows/quality.yml/badge.svg)](https://github.com/jumpserver/installer/actions/workflows/quality.yml)

[English](../README.md) · [简体中文](README.zh-hans.md) · [繁體中文](README.zh-hant.md)

</div>

## 概览

JumpServer 是开源的堡垒机与特权访问管理（PAM）平台，为 SSH、RDP、Kubernetes、数据库、Web 站点、RemoteApp 和 VirtualApp 等资产提供带审计的、基于角色的访问控制。

本仓库是 JumpServer 官方安装器。它负责准备主机环境、在需要时安装 Docker 与 Docker Compose、生成 Compose 编排、加载镜像、迁移数据库结构，并通过 `jmsctl.sh` 管理部署的日常运维。

- 应用源码：[jumpserver/jumpserver](https://github.com/jumpserver/jumpserver)
- 官方文档：[jumpserver.com/docs](https://www.jumpserver.com/docs)
- 配置参数说明：[环境变量](https://docs.jumpserver.org/zh/v3/guide/env/)

## 目录

- [环境要求](#环境要求)
- [快速开始](#快速开始)
- [端口](#端口)
- [管理命令](#管理命令)
- [配置](#配置)
- [升级](#升级)
- [离线安装](#离线安装)
- [企业版 JDMC](#企业版-jdmc)
- [SSH Ansible 执行器](#ssh-ansible-执行器)
- [仓库结构](#仓库结构)
- [开发](#开发)
- [社区](#社区)
- [许可证](#许可证)

## 环境要求

| 项目 | 要求 |
| --- | --- |
| 操作系统 | 使用 systemd 的 Linux |
| 架构 | `x86_64` 或 `aarch64` |
| 内核 | 4.0 及以上 |
| 权限 | `root` 或具有 `sudo` 权限的用户 |
| 资源 | 小型生产部署建议从 4 vCPU、8 GiB 内存、100 GiB 磁盘起步 |
| 网络 | 可访问镜像仓库，或准备离线镜像包 |
| 时间 | 建议启用 NTP 时间同步 |

`./jmsctl.sh install` 会在缺失时安装 Docker 29.10.1 和 Docker Compose v2.40.3。如果主机无法使用 systemd，请先自行安装 Docker 与 Compose 插件，并在运行安装器时设置 `UNCHECK_DEPENDENCIES=1`。

## 快速开始

### 从 Release 压缩包安装（推荐）

```bash
# 将 vX.Y.Z 替换为 https://github.com/jumpserver/installer/releases 中的最新版本
VERSION=vX.Y.Z
curl -fLO "https://github.com/jumpserver/installer/releases/download/${VERSION}/jumpserver-installer-${VERSION}.tar.gz"
curl -fLO "https://github.com/jumpserver/installer/releases/download/${VERSION}/jumpserver-installer-${VERSION}.tar.gz.sha256"
sha256sum -c "jumpserver-installer-${VERSION}.tar.gz.sha256"
tar -xzf "jumpserver-installer-${VERSION}.tar.gz"
cd "jumpserver-installer-${VERSION}"

sudo ./jmsctl.sh install
sudo ./jmsctl.sh start
```

`install` 会完成首次安装：

1. 在缺失时安装并配置 Docker 和 Docker Compose。
2. 收集配置并写入 `/opt/jumpserver/config/config.txt`。
3. 加载镜像，初始化或迁移数据库结构。
4. 在企业版中安装 JDMC。

`start` 完成后访问 `http://<主机地址>/`，配置了 TLS 时访问 HTTPS 地址。默认用户名为 `admin`，初始密码会在安装结束时输出，请在首次登录后立即修改。

### 从源码安装

```bash
git clone https://github.com/jumpserver/installer.git
cd installer
git checkout <tag>

sudo ./jmsctl.sh install
sudo ./jmsctl.sh start
```

> [!NOTE]
> 离线主机请先按[离线安装](#离线安装)准备镜像包，再执行 `install`。

## 端口

| 端口 | 默认用途 | 服务 | 说明 |
| --- | --- | --- | --- |
| `80` | HTTP | Web 控制台和 API | 设置 `HTTP_PORT=0` 可关闭 |
| `443` | HTTPS | Web 控制台和 API | 配置 `HTTPS_PORT` 和证书后使用 |
| `2222` | TCP | KoKo SSH | 连接资产的 SSH 与 SFTP 会话 |
| `5001` | TCP | KoKo Web 代理 | 会发布到宿主机，可通过 `WEB_PROXY_ALLOWED_HOSTS` 限制来源 |
| `3389` | TCP | Razor RDP | 企业版 |
| `3390` | TCP | XRDP | 企业版，默认关闭 |
| `5525` | TCP | Magnus | 企业版数据库代理 |
| `15900` | TCP | NEC | 企业版 VNC |

Docker 网络 `DOCKER_SUBNET`（默认 `192.168.250.0/24`）和 `DOCKER_EXECUTOR_SUBNET`（默认 `192.168.252.0/24`）不能与宿主机、资产、VPN 或其他 Docker 网段冲突。

## 管理命令

在安装器目录中执行 `sudo ./jmsctl.sh <命令>`。单独管理 JDMC 可使用 `start jdmc`、`stop jdmc`、`restart jdmc`、`status jdmc` 或 `tail jdmc`。

| 命令 | 说明 |
| --- | --- |
| `install` | 首次安装：配置 Docker、写入配置、加载镜像、初始化数据库；企业版还会安装 JDMC |
| `upgrade [版本]` | 升级到指定版本，或升级到安装器自带的版本 |
| `check_update` | 检查是否有新版本 |
| `config [ntp\|init\|port\|ssl\|env]` | 调整 NTP、配置、服务端口、TLS 或环境设置 |
| `start` | 启动所有已启用的服务 |
| `stop [服务]` | 停止并移除容器，`VOLUME_DIR` 中的数据会保留 |
| `restart [服务]` | 重启全部服务或单个服务 |
| `status` | 查看容器状态；企业版同时显示 JDMC 状态 |
| `close [服务]` | 停止应用容器，但保留数据库容器运行 |
| `down [服务]` | 停止并移除全部容器，或移除单个服务 |
| `prepare [服务 ...]` | 只准备目录、权限和密钥，不启动服务 |
| `prepare --containers <容器名 ...>` | 使用已安装的镜像准备已停止的容器 |
| `load_image` | 从离线镜像目录加载镜像 |
| `backup_db` | 备份数据库 |
| `backup_no_audit` | 备份数据库但不包含审计表 |
| `backup_audit` | 仅备份审计表 |
| `restore_db [文件]` | 从备份文件恢复数据库 |
| `tail [服务]` | 查看全部服务或单个服务的日志 |
| `raw <compose 参数...>` | 直接执行安装器生成的 `docker compose` 命令 |
| `video-worker <start\|stop\|restart\|status>` | 管理企业版 video-worker |
| `uninstall` | 移除容器和网络，并可选清理文件、镜像和 Docker 程序；破坏性步骤会先确认 |
| `version` | 显示当前安装版本 |

执行 `./jmsctl.sh --help` 可查看完整命令摘要。

## 配置

安装完成后，配置位于 `/opt/jumpserver/config`：

```text
/opt/jumpserver/config/
├── config.txt          # 主配置，会挂载到各个容器
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

`config.txt` 是所有容器共享的环境变量文件，因此 KoKo、Core 等组件不需要单独的配置文件。安装器还会生成受限的 `config_safe.txt`，只向需要的组件传递配置值。带注释的完整示例见 `config-example.txt`。

### 常用配置项

| 配置项 | 默认值 | 作用 |
| --- | --- | --- |
| `VOLUME_DIR` | `/data/jumpserver` | 持久化数据、录像、任务日志和备份 |
| `SECRET_KEY`、`BOOTSTRAP_TOKEN` | 自动生成 | 迁移环境时必须保留的密钥 |
| `HTTP_PORT`、`HTTPS_PORT` | `80`、`443` | Web 端口，设为 `0` 可关闭 |
| `SERVER_NAME`、`SSL_CERTIFICATE`、`SSL_CERTIFICATE_KEY` | 空 | 启用 HTTPS |
| `DB_ENGINE` | `postgresql` | 内置数据库类型 |
| `DB_HOST` | `postgresql` | 内置数据库使用 `postgresql` 或 `mysql`，也可填写外置数据库地址 |
| `DB_IMAGE` | 随版本而定 | 覆盖内置数据库镜像，例如 `mysql:8.0` |
| `REDIS_HOST`、`REDIS_PORT`、`REDIS_PASSWORD` | `redis`、`6379` | 内置 Redis 连接 |
| `DOCKER_SUBNET`、`DOCKER_EXECUTOR_SUBNET` | `192.168.250.0/24`、`192.168.252.0/24` | 容器网段 |
| `TZ` | `Asia/Shanghai` | 容器时区 |
| `IMAGE_PULL_PREFIX`、`NAMESPACE`、`IMAGE_PULL_SCOPE`、`IMAGE_PULL_POLICY` | 空、`jumpserver`、`jumpserver`、`Always` | 镜像来源与本地命名 |
| `USE_XPACK` | `0` | 部署 JDMC 等企业版组件 |
| `KOKO_SSH_PORT`、`RAZOR_RDP_PORT`、`MAGNUS_PORT`、`NEC_VNC_PORT` | `2222`、`3389`、`5525`、`15900` | 组件端口 |
| `ANSIBLE_EXECUTOR_*`、`CELERY_PRIVILEGED` | 内置默认值 | 执行器部署与 Celery 隔离 |
| `*_ENABLED` | `1` | 设为 `0` 可关闭对应服务 |

### 内置数据库

新安装默认使用 PostgreSQL 18.7。如需使用内置 MySQL 8.0，请设置 `DB_ENGINE=mysql`、`DB_HOST=mysql` 和 `DB_IMAGE=mysql:8.0`；交互式安装也会询问内置数据库镜像。未设置 `DB_IMAGE` 时，新安装使用 MariaDB 10.6。

已有的 `VOLUME_DIR/mysql/data` 或 `VOLUME_DIR/mariadb/data` 决定继续使用原数据库。修改 `DB_IMAGE` 不会迁移已有数据。离线安装需要自行提供所选数据库镜像。

## 升级

```bash
sudo ./jmsctl.sh upgrade
```

在线升级会拉取所需镜像，离线升级会从本地镜像包加载。升级前请备份环境，并保留 `VOLUME_DIR`、`SECRET_KEY` 和 `BOOTSTRAP_TOKEN`。

从 v5.3.0 起，KoKo 统一提供 Chen、Kael 和 Lion 的功能。升级前请结束进行中的 Chen 会话，等旧服务上传完待传的审计和录像。通过 jmsctl 启动或重启 KoKo 时，会先停止旧的独立容器并关闭它们的自动重启。执行 `jmsctl stop` 或 `jmsctl stop koko` 时，会在读取 Compose 配置前直接通过 Docker 停用这些旧容器。即使 Compose 不可用，也可以按名称单独停用，例如 `jmsctl stop chen`。执行升级时，这一步会在数据库迁移前完成。升级成功后会删除这些容器，保留挂载的数据。KoKo 直接复用 `${VOLUME_DIR}/kael/data`，默认将新的 Chen 状态写入 `${VOLUME_DIR}/koko/data/chen`。旧 Chen 数据目录会保留。原先单独部署 Chen、Kael 或 Lion 的节点，如需在本机继续提供这些功能，请启用 KoKo。新版工作台随 `KOKO_ENABLED` 启停，旧配置 `CHEN_ENABLED=0` 只适用于独立服务。

企业版的 Razor 镜像同时提供 RDP、Magnus 数据库代理和 NEC VNC 服务。此前仅部署 Magnus 或 NEC 的节点需要启用 Razor。`RAZOR_ENABLED` 统一控制容器及三个监听端口。升级沿用原有端口、数据目录和证书，并清理旧的独立容器。

### 升级时的数据库备份

使用外置 MySQL 或 PostgreSQL 且未启用 `HA_MODE=1` 时，备份客户端镜像缺失、加载或拉取失败只会输出警告，升级会继续到备份步骤。本地没有可用的客户端镜像时跳过备份；镜像可用时正常尝试备份。内置数据库和应用必需镜像仍必须准备成功。

所有数据库备份都失败时，安装器会提示：

```text
Failed to backup the database. Continue to upgrade? [Y/n] (Timeout: 30s, default: y):
```

输入 `y`（不区分大小写）或直接回车继续，输入 `n` 中止。30 秒没有输入时提示超时并继续。其他输入或输入流关闭会中止升级。超时仅用于此备份失败确认，其他确认保持原有行为；`AUTO_INSTALL=1` 按既有自动安装规则采用默认值 `y`。

继续升级表示接受本次安装器没有成功备份数据库，请确保 DBA 或云数据库提供了可恢复的备份。

如已自行完成备份，也可以显式跳过备份及备份客户端镜像准备：

```bash
SKIP_BACKUP_DB=1 ./jmsctl.sh upgrade
```

表结构迁移仍由 Core 连接数据库执行。单独执行 `backup_db` 失败仍返回非零状态，不会触发升级确认。此流程不改变备份客户端版本，PostgreSQL 客户端与服务端版本不兼容时仍可能备份失败。`SKIP_BACKUP_DB` 通过命令环境传入，不是 `config.txt` 配置项。

内置 PostgreSQL 10 到 17 会在同一次维护中迁移到 PostgreSQL 18。迁移流程、空间要求、定制配置和 JDMC 主备协调见 [PostgreSQL 18 迁移](../docs/zh-hans/postgresql-18-upgrade.md)。

安装或升级不再创建 `/opt/jumpserver/data` 到宿主机数据目录的软链接；已有链接、目录和备份保持原状。配置文件、历史数据迁移及当前安装器路径使用的其他软链接保留。

## 离线安装

离线安装从 `scripts/images/` 加载镜像，而不是从镜像仓库拉取。该目录中的每个镜像都需要一个 `.zst` 归档和一个记录镜像 ID 的 `.sha256` 文件。

```bash
# 将离线镜像包复制到安装器目录后执行
sudo ./jmsctl.sh install
sudo ./jmsctl.sh load_image
```

`install` 和 `upgrade` 会自动识别镜像包，`load_image` 可显式加载。文件布局、镜像清单与仓库前缀设置见[离线安装](../docs/zh-hans/offline-installation.md)。

## 企业版 JDMC

设置 `USE_XPACK=1` 的企业版节点通过独立的 Compose 项目运行 JDMC。社区版跳过 JDMC。连接方式、数据目录及宿主版迁移步骤见[企业版 JDMC](../docs/zh-hans/jdmc.md)。

## SSH Ansible 执行器

安装器会为 CE 和 EE 部署 `jumpserver/ansible-executor`。Core 和 Celery 复用 `ANSIBLE_DOCKER_ENABLED` 开关：开启时通过 SSH 使用常驻执行器，关闭时本地执行。

执行器在独立的 `executor` 网络中监听 2222，不发布宿主机端口，也不挂载 Core 数据或 Docker socket。首次启动会为每套安装生成密钥，重启和升级会保留密钥；请备份 `${CONFIG_DIR}/ansible-executor`。

网络、隔离、资源限制、外部执行器和 `CELERY_PRIVILEGED` 的取舍见 [SSH Ansible 执行器](../docs/zh-hans/ansible-executor.md)。

## 仓库结构

| 路径 | 内容 |
| --- | --- |
| `jmsctl.sh` | 命令行入口 |
| `scripts/` | 按步骤拆分的安装、升级、备份、卸载脚本与共享函数 |
| `scripts/gists/` | 镜像、服务、数据库和 PostgreSQL 迁移辅助模块 |
| `compose/` | 按服务拆分的 Docker Compose 片段 |
| `config-example.txt` | 带注释的配置参考 |
| `config_init/` | MySQL、MariaDB、Redis、OpenBao、Loki 和执行器的初始配置模板 |
| `locale/` | `en`、`zh_CN` 和 `zh_Hant` 命令行翻译 |
| `tests/` | Bash 回归测试 |
| `docs/` | 英文、简体中文和繁体中文的专题文档 |
| `.github/workflows/` | 质量检查、OSS 镜像同步和 Release 草稿 |

## 开发

提交改动前请运行 Shell 语法检查和回归测试：

```bash
find . -type f -name '*.sh' -print0 | while IFS= read -r -d '' file; do
  bash -n "${file}"
done

bash tests/run.sh
```

Docker 与 Compose 二进制镜像的维护说明见 [Docker 与 Compose 镜像同步](../docs/zh-hans/docker-mirror.md)。

## 社区

- 文档：<https://www.jumpserver.com/docs>
- Releases：<https://github.com/jumpserver/installer/releases>
- Issues：<https://github.com/jumpserver/jumpserver/issues>
- Discord：<https://discord.gg/jumpserver>

## 许可证

Copyright (c) 2014-2026 FIT2CLOUD, All rights reserved.

本项目基于 GNU General Public License version 3（GPLv3）许可，与 [JumpServer 主仓库](https://github.com/jumpserver/jumpserver)一致。完整许可文本请参阅 [LICENSE](../LICENSE)。
