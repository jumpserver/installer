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
`USE_XPACK=1`。它作为宿主机 systemd 服务安装，不加入 Docker Compose；企业版中
默认启用，如需关闭可设置：

```bash
JDMC_HOST_ENABLED=0
```

安装器默认从 `${REGISTRY}/jumpserver/jdmc:${VERSION}` 拉取 artifact 镜像（未配置
`REGISTRY` 时使用 `jumpserver/jdmc:${VERSION}`），再按需标记为
`${NAMESPACE:-jumpserver}/jdmc:${VERSION}`，从 `/dist` 提取并执行 JDMC 自带的
`scripts/install.sh` 或 `scripts/upgrade.sh`。
也可通过 `JDMC_IMAGE` 指定不受 `REGISTRY` 改写的完整拉取地址；拉取后统一标记为
`${NAMESPACE:-jumpserver}/jdmc:${VERSION}` 供安装器使用。离线包在 JDMC 启用时包含
该镜像；设置 `JDMC_HOST_ENABLED=0` 后不会包含 JDMC 镜像。服务跟随
`jmsctl.sh start/stop/restart/status`
管理，日志可通过 `./jmsctl.sh tail jdmc` 查看。启用时还会自动为 Core 配置
`JDMC_ENABLED=1` 和 `JDMC_SOCK_PATH=/opt/jumpserver/data/unshare/jdmc.sock`。

安装或升级 JDMC 时，安装器会将当前 `VOLUME_DIR` 传递给 JDMC artifact
脚本。JDMC 据此配置宿主机上的 Core Unix Socket、日志和备份路径，因此可以
继续使用已有的自定义持久化目录，不需要为了升级迁移到 `/data/jumpserver`。
JDMC 启动时也会直接读取 `/opt/jumpserver/config/config.txt` 中的
`VOLUME_DIR`；配置变化后可通过 `systemctl restart jdmc` 重新加载 JDMC 路径。
但修改已安装环境的 `VOLUME_DIR` 不会自动搬迁原有 JDMC 数据，必须先停服务并
显式迁移对应的同级 `jdmc` 目录。

从旧 KOTL 升级时，安装器会识别 `/opt/kotl` 和 `kotl.service`，并调用新
JDMC artifact 的升级脚本完成数据、配置和 systemd 服务迁移。旧组件开关会一次性
迁移为 `JDMC_HOST_ENABLED` 并从配置中删除；命令行过渡期仍接受 `--skip-kotl` 和
`./jmsctl.sh tail kotl`，新部署应使用 `--skip-jdmc` 和 `jdmc` 命令目标。
`JDMC_ENABLED` 与 `JDMC_SOCK_PATH` 始终是 Core 集成配置，不作为安装器组件开关使用。

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

config.txt 文件是环境变量配置文件，会挂在到各个容器中，这样可以不必为 koko，core，lion 单独设置配置文件。

具体可以参考： [JumpServer 参数说明文档](https://docs.jumpserver.org/zh/master/admin-guide/env/)
