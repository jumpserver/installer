# SSH Ansible 执行器

[English](../ansible-executor.md) · [简体中文](ansible-executor.md) · [繁體中文](../zh-hant/ansible-executor.md)

安装器部署 `jumpserver/ansible-executor:<版本或分支>`。标签取自 `VERSION` 并去掉末尾的 `-ce` / `-ee`（例如 `v5.1.0-ce` → `v5.1.0`，`dev-ce` → `dev`）。

Core/Celery 复用原 `ANSIBLE_DOCKER_ENABLED` 开关：开启时通过 SSH 使用常驻执行器，关闭时本地执行。页面已保存的开关值继续生效，安装器不再强制指定执行后端；需配套支持该行为的 Core 版本（见 [Core 适配 PR](https://github.com/jumpserver/jumpserver/pull/17797)）。

在线升级时重新拉取对应标签。离线包按镜像 ID 加载更新，运行时不访问镜像仓库。CE 和 EE 共用同一执行器标签，离线包包含执行器。`ansible-executor:latest` 保留给旧版，新安装器不会使用它。CI 从已验证的 digest 打包镜像，发版只映射版本标签，不重新构建镜像。自定义 `OFFLINE_IMAGE_SERVICES` 时应包含 `ansible-executor`。

执行器地址、端口和凭据路径统一使用 Core 默认值。自定义值写入安装器配置文件，由现有 `env_file` 传入 Core/Celery。Compose 仅分别指定两者的网域隧道地址。

## 密钥与启动

`./jmsctl.sh start` 使用执行器镜像中的 `ssh-keygen` 初始化每套安装独立的密钥，等待执行器健康后再启动 Core/Celery。重启、升级保留现有密钥；密钥损坏或只有公钥而缺少私钥时启动失败，不自动轮换身份。

请备份 `${CONFIG_DIR}/ansible-executor`：

- `client/`：服务私钥和固定服务器 host key 的 `known_hosts`，仅只读挂载给 Core/Celery。
- `public/`：服务公钥，只读挂载给执行器。
- `server/`：执行器 SSH host key，持久化并仅挂载给执行器。

## 网络与隔离

执行器只接独立的 `executor` bridge 网络，在内网监听 2222，不发布宿主机端口，也不挂载 Core 数据或 Docker socket。Core/Celery 同时接入业务网 `net` 和执行网 `executor`，Redis、数据库和其他组件只接业务网。

业务网保留原 `DOCKER_SUBNET` 配置。执行网使用 `DOCKER_EXECUTOR_SUBNET`，默认 `192.168.252.0/24`，须避开业务、资产、VPN 和其他 Docker 网段。Docker 的 `bip` 只配置默认网桥，不控制执行网。已有执行网修改子网后，需先停止并移除连接它的容器，删除旧执行网，再通过安装器重新启动；请先等待运行中的任务完成。

`USE_IPV6=1` 时两个网络均启用 IPv6，执行网 IPv6 地址由 Docker 自动分配。Core/Celery 的默认出口由 Docker 自动选择，业务网和执行网均保留出站能力。自定义出口防火墙规则时，需允许实际使用的网络出站。

Core/Celery 不挂载 Docker socket。Celery 恢复 `CELERY_PRIVILEGED` 配置，默认 `true`，以便关闭 Ansible Docker 隔离时，普通 Playbook 仍能在 Celery 内通过 `bwrap` 创建隔离命名空间。Core 和 SSH 执行器不启用 privileged。只使用 SSH 执行器的部署可设置 `CELERY_PRIVILEGED=false`；修改后需要重建 Celery 容器，单纯重启进程不会改变容器权限。privileged 会扩大 Celery 容器的宿主机权限，`bwrap` 隔离不能消除这项部署风险。

关闭 Ansible Docker 隔离不会停止常驻执行器，便于从页面重新开启；本地执行不享有执行器提供的任务 UID 和文件隔离。`ANSIBLE_EXECUTOR_ENABLED=0` 仅控制是否部署本地执行器容器，与功能开关独立。

默认整体资源上限为 4 GiB 内存、2 CPU、1024 PID，可通过配置示例中的选项调整。任务目录使用 `exec,nosuid,nodev` tmpfs，以支持上传的 SSH 包装脚本。

## 地址与运维

资产地址须可从执行器访问，`127.0.0.1` 表示执行器自身。执行网保留访问外部资产的出口，不设为 `internal` 网络。普通自动化由 Celery 执行，但资产页即时账号发现和风险检测由 Core 同步执行，因此两者都需要连接执行器。

网域隧道必须返回创建它的容器：Celery 默认使用 `celery`，Core 默认使用 `core`。多节点部署分别配置 `ANSIBLE_EXECUTOR_GATEWAY_HOST`（Celery）和 `ANSIBLE_EXECUTOR_CORE_GATEWAY_HOST`（Core），使执行器能访问实际执行节点及其动态隧道端口。

使用外部执行器时设置 `ANSIBLE_EXECUTOR_ENABLED=0` 和实际 HOST/PORT，并自行在 `client/` 提供私钥 `client` 及对应地址的可信 `known_hosts`。不得将服务私钥放入任务目录。任务仍通过不同 Linux UID 隔离，共享执行器内核和网络。

分网阻止默认 bridge 之间直接互通，不能替代出口防火墙；宿主机发布的端口、外部服务、Core/Celery 在执行网上监听的服务仍可能可达，应保留认证并按部署环境限制访问。
