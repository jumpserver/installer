# JumpServer Installer

JumpServer Installer 用来安装和管理 JumpServer。

## 环境依赖
  - Linux x86_64
  - Kernel 大于 4.0

## Docker / Compose 下载与 OSS 同步

下载地址和 SHA-256 在 `scripts/const.sh` 中配置。环境变量 `DOCKER_IMAGE_MIRROR=1`
启用 `https://download.jumpserver.org` 加速，也可单独设置 `DOCKER_BIN_HOST`。

在仓库 Actions Secrets 中配置 `OSS_ACCESS_KEY_ID`、`OSS_ACCESS_KEY_SECRET`。
**Sync Docker Binaries to OSS** 会同步 `x86_64`、`aarch64` 两种架构，保留官方子路径：

```text
oss://jms-pkg/linux/static/stable/<arch>/docker-<version>.tgz
oss://jms-pkg/docker/compose/releases/download/<version>/docker-compose-linux-<arch>
```

版本配置变更时自动同步，也可手动 **Run workflow**，选择分支并填写
`docker_version`、`docker_compose_version`（可带 `v`），留空沿用当前版本。
新版本自动计算 SHA-256 和 MD5，原版本仍校验固定 SHA-256。
OSS 上传成功后，只将 `const.sh` 的版本和 SHA-256 提交回所选分支；
参数全部留空时只同步，不提交。历史 OSS 文件保留。

回写使用 `PRIVATE_TOKEN`，未配置时使用 `GITHUB_TOKEN`，需有权推送所选分支。
自动提交通过 `[docker-mirror-synced]` 标记避免重复同步。

## 安装部署

```bash
# 安装，版本是在 static.env 指定的
$ ./jmsctl.sh install
```

## 管理命令

```
# 启动
$ ./jmsctl.sh start

# 重启
$ ./jmsctl.sh restart

# 关闭, 不包含数据库
$ ./jmsctl.sh stop

# 关闭所有
$ ./jmsctl.sh down

# 备份数据库
$ ./jmsctl.sh backup_db

# 查看日志
$ ./jmsctl.sh tail

# 单独管理企业版 video-worker
$ ./jmsctl.sh video-worker {start|stop|restart|status}

```

`video-worker` 的 Compose service、容器名和配置键统一使用该名称；可通过
`VIDEO_WORKER_ENABLED=0` 禁用本地容器，但不关闭 KoKo 的录像转码提交；需要同时设置
`ENABLE_VIDEO_WORKER=true` 才会让 KoKo 提交录像。容器内默认地址为
`VIDEO_WORKER_HOST=http://video-worker:9000`。如果 worker 独立部署，设置
`VIDEO_WORKER_ENABLED=0`、`ENABLE_VIDEO_WORKER=true`，并将
`VIDEO_WORKER_HOST` 设置为 KoKo 容器可访问的外部地址。安装器仅在
`USE_XPACK=1` 时启用此功能；`USE_XPACK=0` 时会强制关闭 KoKo 的 worker 投递。
`USE_XPACK` 是组件部署模式，不代表许可证校验。旧版本的
`VIDEO_ENABLED`、`VIDEO_ENABLE` 以及 `${VOLUME_DIR}/video` 数据目录会在升级时迁移。

## JDMC（企业版）

JDMC 是企业版组件，需要在 `/opt/jumpserver/config/config.txt` 中设置
`USE_XPACK=1`。它作为宿主机 systemd 服务安装，不加入 Docker Compose。社区版不
下载或安装 JDMC；企业版必须安装 JDMC，不再提供单独的启用或禁用开关。

安装器默认根据 `IMAGE_PULL_PREFIX` 拉取 JDMC artifact 镜像（未配置时使用
`jumpserver/jdmc:${VERSION}`），再按需标记为
`${NAMESPACE:-jumpserver}/jdmc:${VERSION}`，从 `/dist` 提取并执行 JDMC 自带的
`scripts/install.sh` 或 `scripts/upgrade.sh`。
JDMC 与 Core 等自有组件使用相同的拉取和重标记规则，企业版离线包始终包含该镜像。
安装或升级时会尝试安装 JDMC 的 HA 宿主机依赖；依赖安装失败或依赖脚本缺失时，
仅输出警告，单机安装或升级继续。启用 HA 前必须补齐依赖；JDMC 的 HA
`setup`、`prepare` 和 `install` 流程会再次检查并安装依赖，失败时中止 HA 部署。
服务跟随 `jmsctl.sh start/stop/restart/status` 管理，日志可通过
`./jmsctl.sh tail jdmc` 查看。安装器会为 Core 配置
`JDMC_SOCK_PATH=/opt/jumpserver/data/unshare/jdmc.sock`；Core 根据企业版自动启用
JDMC 集成。

安装或升级 JDMC 时，安装器会将当前 `VOLUME_DIR` 传递给 JDMC artifact
脚本。JDMC 据此配置宿主机上的 Core Unix Socket、日志和备份路径，因此可以
继续使用已有的自定义持久化目录，不需要为了升级迁移到 `/data/jumpserver`。
JDMC 启动时也会直接读取 `/opt/jumpserver/config/config.txt` 中的
`VOLUME_DIR`；配置变化后可通过 `systemctl restart jdmc` 重新加载 JDMC 路径。
但修改已安装环境的 `VOLUME_DIR` 不会自动搬迁原有 JDMC 数据，必须先停服务并
显式迁移对应的同级 `jdmc` 目录。

从旧 KOTL 升级时，安装器会识别 `/opt/kotl` 和 `kotl.service`，并调用新
JDMC artifact 的升级脚本完成数据、配置和 systemd 服务迁移。安装或升级成功后会清理旧的
`KOTL_ENABLED`、`JDMC_HOST_ENABLED` 和 `JDMC_ENABLED` 配置，历史禁用值不再生效。
命令行使用 `jdmc` 作为 JDMC 服务目标。
`--skip-jdmc` 仅供 JDMC 发起 JumpServer 重启时避免停止自身，不是组件开关。

## 离线镜像清单

`scripts/gists/image.sh` 是离线镜像选择和重标记规则的唯一来源。调用
`get_offline_image_manifest` 会逐行输出以 Tab 分隔的源镜像和离线包目标镜像：

```text
redis:7.4.10-bookworm<TAB>redis:7.4.10-bookworm
registry.example.com/jumpserver/core:VERSION<TAB>jumpserver/core:VERSION
```

安装器的镜像拉取流程和外部 CI 打包流程都应消费该清单，不应分别维护 Redis、
PostgreSQL、Ansible Executor、OpenBao 或 JDMC 的镜像列表。CI 可以通过
`OFFLINE_IMAGE_SERVICES` 传入逗号或空格分隔的服务范围；未设置时，清单使用安装器
当前配置所启用的服务。

`IMAGE_PULL_PREFIX` 只决定 JumpServer 自有镜像的拉取来源，`NAMESPACE` 只决定这些
镜像拉取后的本地运行名称。Redis、数据库和 OpenBao 等基础镜像保留自己的 registry
和 namespace，不使用 `NAMESPACE`；OpenBao 固定使用 `openbao/openbao:2.6.0`。
`IMAGE_PULL_SCOPE` 默认为 `jumpserver`；设置为 `all` 时，基础镜像也从
`IMAGE_PULL_PREFIX` 拉取，但拉取后仍恢复成各自的固定运行名称。

## SSH Ansible 执行器

安装器默认部署 `jumpserver/ansible-executor-ssh:latest`，Core/Celery 固定使用 SSH
后端，需配套支持该后端的 Core 版本（[Core 适配 PR](https://github.com/jumpserver/jumpserver/pull/17797)）。
升级在线安装时重新拉取 `latest`；离线包按镜像 ID 加载更新，运行时不访问镜像仓库。
CE 和 EE 都包含执行器，旧 `ansible-executor:latest` 不再打包。
自定义 `OFFLINE_IMAGE_SERVICES` 时应包含 `ansible-executor`。

`./jmsctl.sh start` 使用执行器镜像中的 `ssh-keygen` 初始化每套安装独立的密钥，
等待执行器健康后再启动 Core/Celery。重启、升级保留现有密钥；密钥损坏或只有公钥
而缺少私钥时启动失败，不自动轮换身份。请备份 `${CONFIG_DIR}/ansible-executor`：

- `client/`：服务私钥和固定服务器 host key 的 `known_hosts`，仅只读挂载给 Core/Celery。
- `public/`：服务公钥，只读挂载给执行器。
- `server/`：执行器 SSH host key，持久化并仅挂载给执行器。

执行器只接独立的 `executor` bridge 网络，在内网监听 2222，不发布宿主机端口，
也不挂载 Core 数据或 Docker socket。Core/Celery 同时接入业务网 `net` 和执行网
`executor`，Redis、数据库和其他组件只接业务网。
业务网保留原 `DOCKER_SUBNET` 配置，执行网使用 Docker 地址池自动分配独立网段。
`USE_IPV6=1` 时两个网络均启用 IPv6，执行网 IPv6 地址由 Docker 自动分配。
Core/Celery 使用 `gw_priority: 1` 保持业务网为默认出口（需 Compose 2.33.1+，
安装器自带的版本已支持，见 [Docker 配置说明](https://docs.docker.com/reference/compose-file/services/#gw_priority)）。
Core/Celery 移除了 Docker socket 和 Celery 的 privileged 设置；旧
`CELERY_PRIVILEGED`、`ANSIBLE_DOCKER_ENABLED` 不再决定此部署的执行方式。
默认整体资源上限为 1 GiB 内存、2 CPU、256 PID，可通过配置示例中的选项调整。
任务目录使用 `exec,nosuid,nodev` tmpfs，以支持上传的 SSH 包装脚本。

资产地址须可从执行器访问，`127.0.0.1` 表示执行器自身。执行网保留访问外部资产的
出口，不设为 `internal` 网络。普通自动化由 Celery 执行，但资产页即时账号发现和
风险检测由 Core 同步执行，因此两者都需要连接执行器。网域隧道必须返回创建它的
容器：Celery 默认使用 `celery`，Core 默认使用 `core`。多节点部署分别配置
`ANSIBLE_EXECUTOR_GATEWAY_HOST`（Celery）和 `ANSIBLE_EXECUTOR_CORE_GATEWAY_HOST`
（Core），使执行器能访问实际执行节点及其动态隧道端口。
使用外部执行器时设置 `ANSIBLE_EXECUTOR_ENABLED=0` 和实际
HOST/PORT，并自行在 `client/` 提供私钥 `client` 及对应地址的可信 `known_hosts`。
不得将服务私钥放入任务目录。任务仍通过不同 Linux UID 隔离，共享执行器内核和网络。
分网阻止默认 bridge 之间直接互通，不能替代出口防火墙；宿主机发布的端口、外部服务、
Core/Celery 在执行网上监听的服务仍可能可达，应保留认证并按部署环境限制访问。

安装/升级不再创建 `/opt/jumpserver/data` 到宿主机数据目录的软链接；已有链接、
目录和备份保持原状。配置文件、历史数据迁移及当前安装器路径使用的其他软链接保留。

## 配置文件说明

全新安装内置 MySQL 8.0 时，在 `config.txt` 中设置 `DB_ENGINE=mysql`、
`DB_HOST=mysql` 和 `DB_IMAGE=mysql:8.0`；交互安装也会询问内置数据库镜像。
不设置 `DB_IMAGE` 时，新安装沿用 MariaDB 10.6。已有的
`VOLUME_DIR/mysql/data` 或 `VOLUME_DIR/mariadb/data` 决定继续使用原数据库，
修改 `DB_IMAGE` 不会迁移已有数据。离线安装需自行提供所选数据库镜像。

配置文件将会放在 /opt/jumpserver/config 中

```
[root@localhost config]# tree .
.
├── config.txt       # 主配置文件
├── mysql
│   └── my.cnf       # mysql 配置文件
|── mariadb
|   └── mariadb.cnf  # mariadb 配置文件
├── nginx            # nginx 配置文件
│   ├── cert
│   │   ├── server.crt
│   │   └── server.key
│   ├── lb_http_server.conf
│   └── lb_ssh_server.conf
├── README.md
└── redis
    └── redis.conf  # redis 配置文件

6 directories, 11 files
```

### config.txt 说明

config.txt 文件是环境变量配置文件，会挂载到各个容器中，这样可以不必为 koko、core 单独设置配置文件。

具体可以参考： [JumpServer 参数说明文档](https://docs.jumpserver.org/zh/master/admin-guide/env/)

## 许可证

本项目采用 GNU General Public License version 3（GPLv3），与 [JumpServer 主库](https://github.com/jumpserver/jumpserver)保持一致。完整许可条款见 [LICENSE](LICENSE)。
