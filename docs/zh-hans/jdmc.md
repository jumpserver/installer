# 企业版 JDMC

[English](../jdmc.md) · [简体中文](jdmc.md) · [繁體中文](../zh-hant/jdmc.md)

设置 `USE_XPACK=1` 的企业版节点使用同版本的 JDMC 运行镜像。安装器从镜像中提取 Compose 文件，以独立的 `jdmc` 项目启动容器。企业版离线包包含这个镜像。社区版跳过 JDMC，卸载时保留同机的 JDMC 和 KOTL 数据。

## 启动与 Core 通信

安装器在 Core 数据库迁移前启动 JDMC。Core 未启动或回调证书未就绪时，宿主 root 仍可通过 PAM 登录。Core 通过 JDMC 的 HTTPS 管理端口（默认 `9898`）回调，校验服务端证书并使用 Bearer Token 认证。JDMC 使用本机节点密钥签名，通过 `http://core.host.internal:8080` 调用 Core。安装器将 Core 发布到宿主 `127.0.0.1:8080`。

节点名、密钥和回调配置只读挂载到 JDMC 和运行 Core 代码的容器。轮换密钥时保留 `node-name`，用 root 持有、权限为 `0400` 的文件原子替换 `config/core/enrollment-secret`。修改 `JDMC_WEB_ADDR` 后执行 `./jmsctl.sh start jdmc` 更新回调端口。主备两台节点各自使用本机身份和本机 Core。

通过 `./jmsctl.sh status jdmc` 看状态，`./jmsctl.sh tail jdmc` 看日志。`./jmsctl.sh stop` 停止业务后 JDMC 仍可登录。单独停止管理容器用 `./jmsctl.sh stop jdmc`。宿主重启时，Docker 按 `unless-stopped` 策略恢复之前运行的容器。JDMC 使用宿主 Docker socket，自定义路径可通过 `JDMC_DOCKER_SOCK` 设置。

## 数据与升级

宿主将 JDMC 数据存放在 `VOLUME_DIR` 同级的 `jdmc` 目录中。`config`、`state`、`management`、`backup` 分别挂到容器的 `/data/jdmc` 下。备份节点身份和 TLS 材料时一并保存 `config/core/` 和 `.installer/`。已有独立备份盘继续原地使用。

从单机宿主版 JDMC 或 v4 KOTL 升级时，安装器先检查镜像和 Compose 配置，再停用旧服务并迁移数据。切换后若容器启动失败，请修复提示的问题，从同一目标安装包重试。旧宿主版主备集群须先用原版本完成备份和退役，再全新安装容器主备。

KOTL 的 SFTP 目标、加密凭据、备份计划、历史记录、增量进度和归档随备份目录保留。从 V4 升级后手工导入 V5 许可证。旧 SFTP 目标缺少主机指纹时，在「数据备份」中核对并保存服务器 SHA256 指纹后再传输。自定义日志和录像目录可分别用 `JDMC_HOST_BACKUP_LOG_DIRS` 和 `JDMC_HOST_BACKUP_REPLAY_DIRS` 指定，多个绝对路径用逗号分隔。

## 服务准备

组件的目录、权限和密钥初始化统一由安装器负责：

```bash
./jmsctl.sh prepare ansible-executor video-worker
./jmsctl.sh prepare --containers jms_ansible_executor jms_video-worker
```

不指定服务时准备所有已启用服务。`--containers` 必须指定已停止的容器，按容器实际使用的镜像和运行用户准备，适用于 JDMC 主备及组件补丁后的启动。此命令不启动或重建业务容器，不改写配置或执行数据库操作。JDMC 在两端维护升级及拉起应用前调用它，继续负责主备启停。

## Video Worker

video-worker 的 Compose service、容器名和配置键统一使用该名称。设置 `VIDEO_WORKER_ENABLED=0` 可禁用本地容器，但不会关闭 KoKo 的录像转码提交；还需要同时设置 `ENABLE_VIDEO_WORKER=true`，KoKo 才会提交录像。容器内默认地址为 `VIDEO_WORKER_HOST=http://video-worker:9000`。

如果 worker 独立部署，设置 `VIDEO_WORKER_ENABLED=0`、`ENABLE_VIDEO_WORKER=true`，并将 `VIDEO_WORKER_HOST` 设置为 KoKo 容器可访问的外部地址。安装器仅在 `USE_XPACK=1` 时启用此功能；`USE_XPACK=0` 时会强制关闭 KoKo 的 worker 投递。`USE_XPACK` 是组件部署模式，不代表许可证校验。旧版本的 `VIDEO_ENABLED`、`VIDEO_ENABLE` 以及 `${VOLUME_DIR}/video` 数据目录会在升级时迁移。

单独管理 worker：

```bash
./jmsctl.sh video-worker {start|stop|restart|status}
```
