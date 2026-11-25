# 离线安装

[English](../offline-installation.md) · [简体中文](offline-installation.md) · [繁體中文](../zh-hant/offline-installation.md)

离线安装使用预先导出的镜像，而不是从镜像仓库拉取。

## 镜像包布局

将导出的镜像及其镜像 ID 校验文件放入 `scripts/images/`。该目录至少包含一个 `.zst` 文件时，`install` 和 `upgrade` 会从中加载镜像；否则安装器从镜像仓库拉取。`./jmsctl.sh load_image` 可显式加载该目录。

每个镜像需要两个文件：

```text
scripts/images/
├── core_dev-ce.zst          # docker 镜像归档
└── core:dev-ce.sha256       # 期望的镜像 ID，用于跳过或校验加载
```

归档名称为镜像最后一段路径加 `.zst`。加载器接受原始形式（`core:dev-ce.zst`）或常见的将 `:` 替换为 `_` 的形式（`core_dev-ce.zst`）。校验文件保留原始 basename 并包含镜像 ID。本地已存在相同 ID 的镜像会跳过。

离线包还必须提供所选数据库镜像。

## 镜像选择清单

`scripts/gists/image.sh` 是离线镜像选择和重标记规则的唯一来源。`get_offline_image_manifest` 会逐行输出以 Tab 分隔的源镜像和离线包目标镜像：

```text
redis:8.10.3-trixie	redis:8.10.3-trixie
registry.example.com/jumpserver/core:VERSION	jumpserver/core:VERSION
```

安装器的镜像拉取流程和外部 CI 打包流程都应消费该清单，不应分别维护 Redis、PostgreSQL、Ansible Executor、OpenBao 或 JDMC 的镜像列表。

CI 可以通过 `OFFLINE_IMAGE_SERVICES` 传入逗号或空格分隔的服务范围；未设置时，清单使用安装器当前配置所启用的服务。自定义列表在部署执行器时必须包含 `ansible-executor`。

## 镜像来源

`IMAGE_PULL_PREFIX` 只决定 JumpServer 自有镜像的拉取来源。`NAMESPACE` 只决定这些镜像拉取后的本地运行名称。

Redis、数据库和 OpenBao 等基础镜像保留自己的 registry 和 namespace，不使用 `NAMESPACE`；OpenBao 固定使用 `openbao/openbao:2.6.0`。

`IMAGE_PULL_SCOPE` 默认为 `jumpserver`。设置为 `all` 时，基础镜像也从 `IMAGE_PULL_PREFIX` 拉取，但拉取后仍恢复成各自的固定运行名称。

`DOCKER_IMAGE_MIRROR=1` 是启用 `https://download.jumpserver.org` 镜像的旧选项。设置 `IMAGE_PULL_PREFIX` 时优先使用它。
