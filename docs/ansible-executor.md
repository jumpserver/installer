# SSH Ansible executor

[English](ansible-executor.md) · [简体中文](zh-hans/ansible-executor.md) · [繁體中文](zh-hant/ansible-executor.md)

The installer deploys `jumpserver/ansible-executor:<version-or-branch>`. The tag is derived from `VERSION` with a trailing `-ce` or `-ee` removed (for example, `v5.1.0-ce` becomes `v5.1.0` and `dev-ce` becomes `dev`).

Core and Celery reuse the existing `ANSIBLE_DOCKER_ENABLED` switch: when enabled they use the persistent executor over SSH; when disabled they execute locally. Values already saved in the web UI remain effective; the installer no longer forces an execution backend. A Core version that supports this behavior is required (see the [Core adaptation PR](https://github.com/jumpserver/jumpserver/pull/17797)).

Online upgrades pull the matching tag again. Offline packages update by image ID and never contact a registry at runtime. CE and EE share the same executor tag, and offline packages include the executor. `ansible-executor:latest` is reserved for older versions and is not used by new installers. CI packages images from a verified digest; releases only map version tags and do not rebuild images. When customizing `OFFLINE_IMAGE_SERVICES`, include `ansible-executor`.

The executor address, port, and credential paths use Core defaults. Custom values go into the installer configuration file and are passed to Core and Celery through the existing `env_file`. Compose only sets the gateway tunnel address for each of them.

## Keys and startup

`./jmsctl.sh start` initializes a key pair for each installation with `ssh-keygen` from the executor image, and waits for the executor to become healthy before starting Core and Celery. Restarts and upgrades keep the existing keys. Startup fails if the keys are corrupted or if the public key exists without the private key; identities are never rotated automatically.

Back up `${CONFIG_DIR}/ansible-executor`:

- `client/`: service private key and `known_hosts` with pinned server host keys, mounted read-only to Core and Celery.
- `public/`: service public key, mounted read-only to the executor.
- `server/`: executor SSH host key, persisted and mounted only to the executor.

## Network and isolation

The executor connects only to a dedicated `executor` bridge network, listens on port 2222 inside that network, publishes no host port, and mounts neither Core data nor the Docker socket. Core and Celery join both the business `net` network and the execution `executor` network; Redis, databases, and other components join only the business network.

The business network keeps the existing `DOCKER_SUBNET`. The execution network uses `DOCKER_EXECUTOR_SUBNET`, default `192.168.252.0/24`, which must not overlap business, asset, VPN, or other Docker networks. Docker's `bip` only configures the default bridge and does not control the execution network. After changing the execution subnet on an existing installation, stop and remove the containers attached to it, delete the old execution network, and start again through the installer; wait for running tasks to finish first.

With `USE_IPV6=1`, both networks enable IPv6 and Docker assigns the execution network's IPv6 addresses automatically. Core and Celery egress is chosen by Docker; both networks keep outbound access. Custom egress firewall rules must allow the network actually in use.

Core and Celery do not mount the Docker socket. Celery restores the `CELERY_PRIVILEGED` setting, default `true`, so ordinary playbooks can still create isolated namespaces through `bwrap` inside Celery when Ansible Docker isolation is disabled. Core and the SSH executor are not privileged. Deployments that use only the SSH executor can set `CELERY_PRIVILEGED=false`; changing it requires recreating the Celery container, because restarting the process does not change container privileges. Privileged mode expands Celery's host privileges, and `bwrap` isolation cannot remove that deployment risk.

Disabling Ansible Docker isolation does not stop the persistent executor, so it can be re-enabled from the web UI. Local execution does not get the executor's per-task UID and file isolation. `ANSIBLE_EXECUTOR_ENABLED=0` only controls whether the local executor container is deployed; it is independent of the feature switch.

Default total resource limits are 4 GiB memory, 2 CPUs, and 1024 PIDs; adjust them with the options in the configuration example. Task directories use an `exec,nosuid,nodev` tmpfs to support uploaded SSH wrapper scripts.

## Addressing and operations

Asset addresses must be reachable from the executor; `127.0.0.1` means the executor itself. The execution network keeps egress to external assets and is not marked `internal`. Normal automation runs in Celery, but immediate account discovery and risk detection from the asset page run synchronously in Core, so both need to reach the executor.

The gateway tunnel must return to the container that created it: Celery uses `celery` by default and Core uses `core`. Multi-node deployments set `ANSIBLE_EXECUTOR_GATEWAY_HOST` (Celery) and `ANSIBLE_EXECUTOR_CORE_GATEWAY_HOST` (Core) separately so the executor can reach the actual execution node and its dynamic tunnel port.

To use an external executor, set `ANSIBLE_EXECUTOR_ENABLED=0` and the actual HOST and PORT, and provide the private key `client` plus a trusted `known_hosts` for the corresponding address in `client/`. Never put the service private key in the task directory. Tasks are still isolated by different Linux UIDs but share the executor kernel and network.

Separate networks prevent direct traffic between default bridges; they do not replace egress firewalls. Host-published ports, external services, and services that Core or Celery listen on inside the execution network may still be reachable. Keep authentication enabled and restrict access according to the deployment environment.
