# Enterprise edition: JDMC

[English](jdmc.md) · [简体中文](zh-hans/jdmc.md) · [繁體中文](zh-hant/jdmc.md)

On enterprise nodes with `USE_XPACK=1`, the installer extracts the Compose files from the matching JDMC runtime image and starts a separate `jdmc` project. The enterprise offline bundle includes the image. Community packages skip JDMC and preserve existing JDMC and KOTL data on uninstall.

## Startup and Core connectivity

The installer starts JDMC before the Core database migration. The host root account can sign in through PAM while Core is offline or its callback certificate is unavailable. Core calls JDMC over HTTPS on the management port (default `9898`), verifying the certificate and authenticating with a Bearer token. In the other direction, JDMC signs requests with the local node key and connects to `http://core.host.internal:8080`. The installer publishes Core at `127.0.0.1:8080`.

The node name, secret and callback configuration are mounted read-only into JDMC and the Core processes. To rotate the key, keep `node-name` and atomically replace `config/core/enrollment-secret` with a root-owned file of mode `0400`. After changing `JDMC_WEB_ADDR`, run `./jmsctl.sh start jdmc` to publish the callback port. Each HA node uses its own identity and local Core.

Use `./jmsctl.sh status jdmc` or `./jmsctl.sh tail jdmc` to inspect JDMC. Stopping the application stack with `./jmsctl.sh stop` leaves JDMC available. Use `./jmsctl.sh stop jdmc` to stop it explicitly. Docker restores previously running containers at boot with `unless-stopped`. JDMC uses the host Docker socket, configurable with `JDMC_DOCKER_SOCK`.

## Data and upgrades

The host stores JDMC data in a `jdmc` directory alongside `VOLUME_DIR`. The `config`, `state`, `management`, and `backup` directories are mounted under `/data/jdmc` in the container. Include `config/core/` and `.installer/` when backing up node identity and TLS material. Existing dedicated backup disks remain mounted in place.

For a single-node host JDMC or v4 KOTL installation, the installer checks the image and Compose configuration, stops and disables the old service, then migrates the data. If the container fails to start after cutover, fix the reported problem and retry from the same target installer. For a legacy host HA cluster, back up and retire both nodes with the original version before installing container HA.

KOTL backup migration preserves SFTP targets and encrypted credentials, schedules, history, incremental progress, and archives. Import a V5 license after upgrading from V4. For an old SFTP target with no recorded host key, verify and save the server's SHA256 fingerprint in Data Backup before the next transfer. Custom log or replay directories can be specified with `JDMC_HOST_BACKUP_LOG_DIRS` and `JDMC_HOST_BACKUP_REPLAY_DIRS`, as comma-separated absolute paths.

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
