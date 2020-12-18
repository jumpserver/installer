# JumpServer 安装管理包

从 v2.6 开始，JumpServer 统一了 **社区版** 和 **企业版** 的安装部署包，统一由 本项目 来维护。

installer 可以安装、部署、更新 管理 JumpServer

## 环境依赖
  - CentOS 7

### 修改系统设置如 最大打开文件数

```
$ vim /etc/security/limits.d/20-nproc.conf

*     soft   nofile    65535
*     hard   nofile    65535
*     soft   nproc     65535
*     hard   nproc     65535
root  soft   nproc     unlimited

$ reboot  # 重启服务器
```

## 安装部署

```bash
# 安装，版本是在 static.env 指定的
$ ./jmsctl.sh install

# 可以设置 国内加速源来安装
$ export DOCKER_IMAGE_PREFIX=docker.mirrors.ustc.edu.cn
$ ./jmsctl.sh install

# 检查更新
$ ./jmsctl.sh check_update

# 升级到 static.env 中指定版本
$ ./jmsctl.sh upgrade 

# 升级到知道版本
$ ./jmsctl.sh upgrade v2.6.1
```

## 管理

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

## IPV6 支持

```
# 添加IPV6 转发规则
$ ip6tables -t nat -A POSTROUTING -s 2001:db8:1::/64 -j MASQUERADE
$ firewall-cmd --permanent --zone=public --add-masquerade

# 修改配置文件支持 IPv6
$ vim /opt/jumpserver/config/config.txt
...
USE_IPV6=1
...
```

## 配置文件说明

配置文件将会放在 /opt/jumpserver/config 中

```
[root@jumpserver-qa config]# tree .
.
├── config.txt      # 主配置文件
├── core
│   └── config.yml  # core yml 格式配置文件，可以留空，使用 config.txt 设置
├── koko
│   └── config.yml  # koko yml 格式配置文件，可以留空，使用 config.txt 设置
├── mysql
│   └── my.cnf      # mysql 配置文件
├── nginx           # nginx 配置文件
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

config.txt 文件是环境变量式配置文件，会挂在到各个容器中，这样可以不必为 koko，core，guacamole 单独设置配置文件

config-example.txt 有说明，可以参考



