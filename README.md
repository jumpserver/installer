# JumpServer Installer

JumpServer Installer 用来安装和管理 JumpServer。

## 环境依赖
  - Linux x86_64
  - Kernel 大于 4.0

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

```

## JDMC（企业版）

JDMC 是企业版组件，需要在 `/opt/jumpserver/config/config.txt` 中设置
`USE_XPACK=1`。它作为宿主机 systemd 服务安装，不加入 Docker Compose。社区版不
下载或安装 JDMC；企业版必须安装 JDMC，不再提供单独的启用或禁用开关。

安装器默认根据 `IMAGE_PULL_PREFIX` 拉取 JDMC artifact 镜像（未配置时使用
`jumpserver/jdmc:${VERSION}`），再按需标记为
`${NAMESPACE:-jumpserver}/jdmc:${VERSION}`，从 `/dist` 提取并执行 JDMC 自带的
`scripts/install.sh` 或 `scripts/upgrade.sh`。
也可通过 `JDMC_IMAGE` 指定不受 `IMAGE_PULL_PREFIX` 改写的完整拉取地址；拉取后统一标记为
`${NAMESPACE:-jumpserver}/jdmc:${VERSION}` 供安装器使用。企业版离线包始终包含
该镜像。服务跟随 `jmsctl.sh start/stop/restart/status` 管理，日志可通过
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
命令行过渡期仍接受 `./jmsctl.sh tail kotl`，新部署应使用 `jdmc` 命令目标。
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

## 配置文件说明

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
