# 企业版 JDMC

[English](../jdmc.md) · [简体中文](jdmc.md) · [繁體中文](../zh-hant/jdmc.md)

JDMC 是企业版组件。在 `/opt/jumpserver/config/config.txt` 中设置 `USE_XPACK=1` 启用。它以宿主机 systemd 服务安装，不加入 Docker Compose。社区版不会下载或安装 JDMC；企业版始终安装 JDMC，不提供单独的启用或禁用开关。

## 镜像与安装

安装器根据 `IMAGE_PULL_PREFIX` 拉取 JDMC artifact 镜像（未配置时使用 `jumpserver/jdmc:${VERSION}`），按需标记为 `${NAMESPACE:-jumpserver}/jdmc:${VERSION}`，从 `/dist` 提取并执行其自带的 `scripts/install.sh` 或 `scripts/upgrade.sh`。

JDMC 与 Core 等自有组件使用相同的拉取和重标记规则。企业版离线包始终包含该镜像。

安装或升级时会尝试安装 JDMC 的 HA 宿主机依赖。依赖安装失败或依赖脚本缺失时，安装器只输出警告，单机安装或升级继续。启用 HA 前必须补齐依赖；JDMC 的 HA `setup`、`prepare` 和 `install` 流程会再次检查并安装依赖，失败时中止 HA 部署。

服务跟随 `jmsctl.sh start/stop/restart/status` 管理。通过 `./jmsctl.sh tail jdmc` 查看日志。安装器会为 Core 配置 `JDMC_SOCK_PATH=/opt/jumpserver/data/unshare/jdmc.sock`，Core 在企业版中自动启用 JDMC 集成。

## 数据路径

安装或升级时，安装器会将当前 `VOLUME_DIR` 传递给 JDMC artifact 脚本。JDMC 据此配置宿主机上的 Core Unix Socket、日志和备份路径，因此可以继续使用已有的自定义持久化目录，不需要为了升级迁移到 `/data/jumpserver`。

JDMC 启动时也会直接读取 `/opt/jumpserver/config/config.txt` 中的 `VOLUME_DIR`。修改后执行 `systemctl restart jdmc` 重新加载 JDMC 路径。修改已安装环境的 `VOLUME_DIR` 不会自动搬迁原有 JDMC 数据，必须先停服务并显式迁移同级的 `jdmc` 目录。

## 从 KOTL 迁移

从 KOTL 升级时，安装器会识别 `/opt/kotl` 和 `kotl.service`，并调用新 JDMC artifact 的升级脚本完成数据、配置和 systemd 服务迁移。安装或升级成功后会清理旧的 `KOTL_ENABLED`、`JDMC_HOST_ENABLED` 和 `JDMC_ENABLED` 配置，历史禁用值不再生效。

命令行使用 `jdmc` 作为 JDMC 服务目标。`--skip-jdmc` 仅供 JDMC 发起 JumpServer 重启时避免停止自身，不是组件开关。

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
