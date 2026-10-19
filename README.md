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

## KOTL（企业版）

KOTL 是企业版组件，需要在 `/opt/jumpserver/config/config.txt` 中设置
`USE_XPACK=1`。它作为宿主机 systemd 服务安装，不加入 Docker Compose；企业版中
默认启用，如需关闭可设置：

```bash
KOTL_ENABLED=0
```

安装器会拉取 `${NAMESPACE:-jumpserver}/jdmc:${VERSION}` artifact 镜像，从
`/dist` 提取并执行 KOTL 自带的 `scripts/install.sh` 或 `scripts/upgrade.sh`。
该镜像由 `jdmc` 仓库的 `v4` 分支构建（`deploy/docker/Dockerfile --target dist`），
包内仍使用 `/opt/kotl`、`kotl.service` 和 `kotl.sock`。
离线包也会自动包含该镜像。服务跟随 `jmsctl.sh start/stop/restart/status`
管理，日志可通过 `./jmsctl.sh tail kotl` 查看。启用时还会自动为 Core 配置
`KOTL_ENABLED=1`、`JDMC_ENABLED=1` 和 `/opt/jumpserver/data/unshare/kotl.sock`。

安装或升级 KOTL 时，安装器会将当前 `VOLUME_DIR` 传递给 KOTL artifact
脚本。KOTL 据此配置宿主机上的 Core Unix Socket、日志和备份路径，因此可以
继续使用已有的自定义持久化目录，不需要为了升级迁移到 `/data/jumpserver`。
KOTL 启动时也会直接读取 `/opt/jumpserver/config/config.txt` 中的
`VOLUME_DIR`；配置变化后可通过 `systemctl restart kotl` 重新加载 KOTL 路径。

可用 `./jmsctl.sh start/stop/restart/status kotl` 单独管理宿主机服务。
从 KOTL 页面执行整套应用的启停操作时使用 `--skip-kotl`，避免停止控制台自身。
修改 `KOTL_ENABLED=0` 后执行 `./jmsctl.sh restart`，会停止已安装的 KOTL 服务，
并将 Core 的 `JDMC_ENABLED` 同步为 `0`。

SELinux 为 Enforcing 或 Permissive 时，安装或升级前需准备 `semanage` 和
`restorecon`（`policycoreutils`、`policycoreutils-python-utils`，CentOS 7 使用
`policycoreutils-python`）；离线环境也需提前安装这些依赖。

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
