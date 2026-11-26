# Enterprise edition: JDMC

[English](jdmc.md) · [简体中文](zh-hans/jdmc.md) · [繁體中文](zh-hant/jdmc.md)

JDMC is an enterprise-edition component. Enable it in `/opt/jumpserver/config/config.txt` with `USE_XPACK=1`. It is installed as a host systemd service and is not part of the Docker Compose stack. The community edition neither downloads nor installs JDMC; the enterprise edition always installs it, with no separate enable or disable switch.

## Image and installation

The installer pulls the JDMC artifact image according to `IMAGE_PULL_PREFIX` (`jumpserver/jdmc:${VERSION}` when unset), tags it as `${NAMESPACE:-jumpserver}/jdmc:${VERSION}` when needed, extracts `/dist`, and runs the bundled `scripts/install.sh` or `scripts/upgrade.sh`.

JDMC follows the same pull and retag rules as Core and other first-party components. Enterprise offline packages always include this image.

Installation and upgrades try to install JDMC's HA host dependencies. If dependency installation fails or the dependency script is missing, the installer only emits a warning and single-node installation or upgrade continues. Dependencies must be satisfied before enabling HA; JDMC's HA `setup`, `prepare`, and `install` flows check and install dependencies again and abort HA deployment on failure.

The service follows `jmsctl.sh start/stop/restart/status`. View its logs with `./jmsctl.sh tail jdmc`. The installer configures `JDMC_SOCK_PATH=/opt/jumpserver/data/unshare/jdmc.sock` for Core, and Core enables JDMC integration automatically on the enterprise edition.

## Data paths

During installation or upgrade, the installer passes the current `VOLUME_DIR` to the JDMC artifact scripts. JDMC uses it to configure the host-side Core Unix socket, logs, and backup paths, so an existing custom persistence directory can be reused without migrating to `/data/jumpserver` for the upgrade.

JDMC also reads `VOLUME_DIR` from `/opt/jumpserver/config/config.txt` at startup. After changing it, run `systemctl restart jdmc` to reload JDMC paths. Changing `VOLUME_DIR` on an installed environment does not move existing JDMC data: stop the service and explicitly migrate the sibling `jdmc` directory first.

## Migration from KOTL

When upgrading from KOTL, the installer detects `/opt/kotl` and `kotl.service` and invokes the new JDMC artifact upgrade script to migrate data, configuration, and the systemd service. After a successful install or upgrade, the legacy `KOTL_ENABLED`, `JDMC_HOST_ENABLED`, and `JDMC_ENABLED` settings are removed; historical disabled values no longer take effect.

The command-line service target is `jdmc`. `--skip-jdmc` exists only so a JDMC-initiated JumpServer restart does not stop JDMC itself; it is not a component switch.

## Service preparation

Directories, permissions, and key initialization for all components are owned by the installer:

```bash
./jmsctl.sh prepare ansible-executor video-worker
./jmsctl.sh prepare --containers jms_ansible_executor jms_video-worker
```

Without a service list, all enabled services are prepared. `--containers` requires stopped containers and prepares them using the images and runtime users actually used by those containers; it suits JDMC primary/standby nodes and post-patch component starts. The command does not start or recreate business containers, rewrite configuration, or touch the database. JDMC calls it on both nodes before maintenance upgrades and before bringing the application back, and remains responsible for primary/standby start and stop.

## Video worker

The video-worker Compose service, container name, and configuration keys all use the `video-worker` name. Set `VIDEO_WORKER_ENABLED=0` to disable the local container without disabling KoKo's recording-transcode submission. KoKo submits recordings only when `ENABLE_VIDEO_WORKER=true` is also set. The default in-container address is `VIDEO_WORKER_HOST=http://video-worker:9000`.

For an independently deployed worker, set `VIDEO_WORKER_ENABLED=0`, `ENABLE_VIDEO_WORKER=true`, and point `VIDEO_WORKER_HOST` at an address reachable from the KoKo container. The installer enables this feature only when `USE_XPACK=1`; with `USE_XPACK=0` it forces KoKo worker submission off. `USE_XPACK` selects the component deployment mode and is not license validation. Legacy `VIDEO_ENABLED`, `VIDEO_ENABLE`, and `${VOLUME_DIR}/video` data are migrated on upgrade.

Manage the worker separately with:

```bash
./jmsctl.sh video-worker {start|stop|restart|status}
```
