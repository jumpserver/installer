# Offline installation

[English](offline-installation.md) · [简体中文](zh-hans/offline-installation.md) · [繁體中文](zh-hant/offline-installation.md)

An offline installation uses pre-exported images instead of an image registry.

## Image package layout

Place the exported images and their image-ID checksums in `scripts/images/`. If that directory contains at least one `.zst` file, `install` and `upgrade` load images from it; otherwise the installer pulls images from the registry. `./jmsctl.sh load_image` loads the directory explicitly.

Each image needs two files:

```text
scripts/images/
├── core_dev-ce.zst          # docker image archive
└── core:dev-ce.sha256       # expected image ID, used to skip or validate loads
```

The archive name is the image's last path component plus `.zst`. The loader accepts either the plain form (`core:dev-ce.zst`) or the widely used form with `:` replaced by `_` (`core_dev-ce.zst`). The checksum file keeps the plain basename and contains the image ID. Images that are already present with the same ID are skipped.

Offline packages must also provide the selected database image.

## Image selection manifest

`scripts/gists/image.sh` is the single source of truth for offline image selection and retagging rules. `get_offline_image_manifest` prints tab-separated source and offline-package target images:

```text
redis:8.10.3-trixie	redis:8.10.3-trixie
registry.example.com/jumpserver/core:VERSION	jumpserver/core:VERSION
```

Both the installer's image pull flow and external CI packaging must consume this manifest. Do not maintain separate image lists for Redis, PostgreSQL, Ansible Executor, OpenBao, or JDMC.

CI can pass `OFFLINE_IMAGE_SERVICES` as a comma- or space-separated service list. When unset, the manifest uses the services enabled by the installer's current configuration. A customized list must include `ansible-executor` when that component is deployed.

## Image sources

`IMAGE_PULL_PREFIX` only sets the source for JumpServer-owned images. `NAMESPACE` only sets the local runtime name of those images after pulling.

Infrastructure images such as Redis, databases, and OpenBao keep their own registry and namespace and do not use `NAMESPACE`. OpenBao is fixed at `openbao/openbao:2.6.0`.

`IMAGE_PULL_SCOPE` defaults to `jumpserver`. When set to `all`, infrastructure images are also pulled from `IMAGE_PULL_PREFIX`, then restored to their canonical runtime names.

`DOCKER_IMAGE_MIRROR=1` is a legacy option that enables the `https://download.jumpserver.org` mirror. `IMAGE_PULL_PREFIX` takes precedence when set.
