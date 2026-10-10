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

# 还原数据库
$ ./jmsctl.sh restore_db /path/to/backup.dump.gz

# 查看日志
$ ./jmsctl.sh tail

```

PostgreSQL 数据库备份只包含应用使用的 schema。使用与应用相同的数据库连接
配置，按 `search_path` 的有效搜索顺序定位 `django_migrations`，选择该表所在
的 schema；搜索路径中找不到迁移表时，使用 `current_schema()`，通常为
`public`。多个 schema 都有同名迁移表时，选择搜索路径中第一个匹配的表；
不在有效搜索路径中的 schema 不参与选择。例如两者都有迁移表时，
`public,test1` 选择 `public`，`test1,public` 选择 `test1`；若 `test1` 没有迁移
表而 `public` 有，则仍选择 `public`。连接失败或无有效 schema 时操作失败。
审计日志备份中的表也限定在所选 schema。此方式适用于应用表与迁移表集中在
同一 schema 的部署，应用账号的 `search_path` 应与程序使用的 schema 一致。
自定义格式 `.dump` / `.dump.gz` 还原只处理当前 schema，即使旧备份包含其他
schema，也不会恢复它们。先生成还原 SQL，再使用 `DROP ... RESTRICT` 清理
目标 schema 的表、视图、序列、函数和类型，包括备份之后新增的对象；保留
schema 本身，原有 owner、schema 授权和默认权限无需重建。不额外查询跨
schema 依赖图，依赖阻止删除时由 PostgreSQL 报错。清理和还原在同一事务
内执行，任意步骤失败都会回滚。执行账号需要具备删除和重建这些对象的
权限。复杂自定义对象的依赖顺序无法清理时，同样失败回滚。
SQL 格式的审计日志备份沿用 SQL 导入方式。

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
