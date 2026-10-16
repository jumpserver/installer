# JumpServer Installer

JumpServer Installer 用来安装和管理 JumpServer。

## 环境依赖
  - Linux x86_64
  - Kernel 大于 4.0

## Docker / Compose 下载与 OSS 同步

二进制下载地址直接在 `scripts/const.sh` 中定义。环境变量 `DOCKER_IMAGE_MIRROR=1`
会将 Docker 和 Compose 的下载域名切换为 `https://download.jumpserver.org`；
未启用该开关时，可通过环境变量 `DOCKER_BIN_HOST` 指定其他下载域名。
安装器始终使用 `scripts/const.sh` 中固定的 SHA-256 校验下载内容。

GitHub Actions 的 **Sync Docker Binaries to OSS** 自动读取该文件的版本号及
两种架构（`x86_64`、`aarch64`）的 SHA-256，从官方源下载并校验全部文件后，
上传二进制及 `.sha256`、`.md5` 文件到北京地域的 `jms-pkg` bucket。
对象路径保留官方 URL 去掉域名后的部分：

```text
oss://jms-pkg/linux/static/stable/<arch>/docker-<version>.tgz
oss://jms-pkg/docker/compose/releases/download/<version>/docker-compose-linux-<arch>
```

在 installer 仓库的 **Settings → Secrets and variables → Actions** 中添加：

- `OSS_ACCESS_KEY_ID`
- `OSS_ACCESS_KEY_SECRET`

凭证通过 ossutil 环境变量传入，不写入仓库或配置文件。RAM 授权范围应覆盖
`jms-pkg/linux/static/stable/*` 和 `jms-pkg/docker/compose/releases/download/*`
的对象写入及上传所需权限。

向 `dev`、`master`、`main` 或 `v*` 分支推送版本配置、同步脚本或 Workflow
的变更时自动同步，也可在 Actions 页面手动 **Run workflow**，同步所选分支
声明的版本。升级版本时需一并更新两种架构的 SHA-256，无需修改 Workflow。
上传逐文件执行，不删除历史版本或 bucket 中的其他对象。

本地仅下载和校验、不上传的检查方式：

```bash
bash utils/prepare_docker_mirror.sh /tmp/docker-mirror
```

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
