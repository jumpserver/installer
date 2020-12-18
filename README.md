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
