# PostgreSQL 18 迁移

[English](../postgresql-18-upgrade.md) · [简体中文](postgresql-18-upgrade.md) · [繁體中文](../zh-hant/postgresql-18-upgrade.md)

新安装默认使用 `postgres:18.7-trixie`。

## Compose 布局

统一的 `compose/postgresql.yml` 显式设置 `PGDATA=/var/lib/postgresql/data`，继续把 `${VOLUME_DIR}/postgresql/data` 挂载到该目录，以兼容 JDMC 的主备重建、回切和启动写入隔离。

同时显式挂载 `${VOLUME_DIR}/postgresql:/var/lib/postgresql`，避免 PostgreSQL 18 镜像自动创建额外匿名卷，导致 JDMC 的 Compose 挂载一致性校验失败。

主 Compose 固定为 `postgres:18.7-trixie`，不需要数据库镜像配置项。旧版本按实际数据版本选择镜像，仅在迁移前自动生成 `${CONFIG_DIR}/postgresql/image-<tag>.yml` 运行时镜像覆盖文件，使用相同的 `PGDATA`；迁移完成后使用主 Compose 中的 18 镜像。

运行时文件会保留，避免影响 JDMC 已记录的 Compose 绑定。JDMC 升级已有主备时继续使用已绑定的旧 Compose 文件，在协调迁移切换时更新数据库配置和绑定，不改写旧文件。

单机生成数据库 Compose 命令时会补齐父目录的可穿越权限，避免旧目录为 `700` 时容器无法访问；数据目录 `postgresql/data` 的权限保持不变。

## 从旧版本升级

从 JumpServer 5.0 等旧应用版本升级时，内置 PostgreSQL 10–17 会在同一次维护中迁移到 `postgres:18.7-trixie`。

安装器会：

1. 加载旧镜像和 18 镜像。
2. 停止应用写入并禁用自动重启。
3. 使用 18 客户端导出全部数据库和角色。
4. 在隔离目录恢复并校验结果。
5. 切换数据目录。
6. 更新业务表结构并恢复原先运行的应用。

迁移前仍按 `PG_VERSION` 选择旧镜像；不能让 18 直接打开旧数据。外置数据库不会被升级。

旧目录、逻辑备份和进度保存在 `${VOLUME_DIR}/postgresql/data.upgrade18/`：

- `original/` 是原数据。
- `cluster.sql` 包含全库及角色凭据。

目录和文件必须保持私有。迁移备份是必需步骤，不受 `SKIP_BACKUP_DB` 影响。中断时应用保持停止，重试同一升级继续处理；完成迁移前普通启动会被拒绝。

恢复业务后新产生的数据不会写回旧目录，不能直接把旧目录切回去。空间预检按旧数据三倍加 1 GiB 估算；大对象或高压缩数据可能需要更多空间。

自动迁移要求可验证的管理员账号、标准数据路径和配置；自定义表空间、外置配置或 SSL 文件、逻辑复制、非 libc 模板区域设置等定制部署在预检时中止，需要单独迁移。原镜像及旧数据不会自动清理。

## JDMC 主备

JDMC 主备由两台协调维护：停止业务和选举，迁移主库，重新建立 18 备库，校验流复制、同步提交和启动写入隔离，再更新应用并退出维护。

两台 JDMC 必须先具备此迁移能力。新的全量升级包声明 `maintenance-pg18-v1`，旧 JDMC 会拒绝该包，避免跳过数据库迁移。`pg_rewind` 不承担数据库大版本迁移。

参考 PostgreSQL 的 [升级说明](https://www.postgresql.org/docs/18/upgrading.html) 和 [主备版本要求](https://www.postgresql.org/docs/18/warm-standby.html)。
