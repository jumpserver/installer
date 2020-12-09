# JumpServer 安装管理包

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

## 安装

```bash
# 安装
$ ./jmsctl.sh install

# 启动
$ ./jmsctl.sh start

# 重启
$ ./jmsctl.sh restart

# 干掉容器重新启动
$ ./jmsctl.sh down && ./jmsctl.sh start

# 备份
$ ./jmsctl.sh backup

# 查看日志
$ ./jmsctl.sh log

# 添加IPV6 转发规则
$ ip6tables -t nat -A POSTROUTING -s 2001:db8:1::/64 -j MASQUERADE
$ firewall-cmd --permanent --zone=public --add-masquerade

```



