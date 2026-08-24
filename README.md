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

安装器会拉取 `${NAMESPACE:-jumpserver}/kotl:${VERSION}` artifact 镜像，从
`/dist` 提取并执行 KOTL 自带的 `scripts/install.sh` 或 `scripts/upgrade.sh`。
离线包也会自动包含该镜像。服务跟随 `jmsctl.sh start/stop/restart/status`
管理，日志可通过 `./jmsctl.sh tail kotl` 查看。启用时还会自动为 Core 配置
`KOTL_ENABLED=1`、`JDMC_ENABLED=1` 和 `/opt/jumpserver/data/unshare/kotl.sock`。

当前 KOTL 的宿主机路径固定使用 `/data/jumpserver`，因此启用时
`VOLUME_DIR` 也必须保持为 `/data/jumpserver`。

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
