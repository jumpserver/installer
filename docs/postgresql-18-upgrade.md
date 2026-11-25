# PostgreSQL 18 migration

[English](postgresql-18-upgrade.md) · [简体中文](zh-hans/postgresql-18-upgrade.md) · [繁體中文](zh-hant/postgresql-18-upgrade.md)

New installations use `postgres:18.7-trixie` by default.

## Compose layout

The unified `compose/postgresql.yml` explicitly sets `PGDATA=/var/lib/postgresql/data` and keeps `${VOLUME_DIR}/postgresql/data` mounted at that path. This is compatible with JDMC primary/standby rebuild, failback, and startup write isolation.

The file also explicitly mounts `${VOLUME_DIR}/postgresql:/var/lib/postgresql` so the PostgreSQL 18 image does not create additional anonymous volumes, which would make JDMC's Compose mount consistency check fail.

The main Compose file is fixed at `postgres:18.7-trixie`; there is no database image configuration item. Older versions select the image according to the actual data version. Before migration, the installer only generates a runtime override at `${CONFIG_DIR}/postgresql/image-<tag>.yml` using the same `PGDATA`; after migration it uses the 18 image from the main Compose file.

Runtime files are retained so they do not affect Compose bindings already recorded by JDMC. When JDMC upgrades an existing primary/standby pair, it keeps using the bound old Compose files and updates the database configuration and binding while coordinating the migration switch; it does not rewrite the old files.

Single-node database Compose generation fills in the parent directory's traverse permission, so an old directory with mode `700` does not block container access. The data directory `postgresql/data` keeps its permissions unchanged.

## Upgrading from older versions

When upgrading from application versions such as JumpServer 5.0, built-in PostgreSQL versions 10 through 17 are migrated to `postgres:18.7-trixie` during the same maintenance window.

The installer:

1. Loads the old image and the 18 image.
2. Stops application writes and disables automatic restart.
3. Uses the 18 client to export all databases and roles.
4. Restores into an isolated directory and verifies the result.
5. Switches the data directory.
6. Updates the business schema and restores the application that was running.

Before migration the installer still selects the old image based on `PG_VERSION`; PostgreSQL 18 must never open old data directly. External databases are not upgraded.

Old directories, the logical backup, and progress are stored in `${VOLUME_DIR}/postgresql/data.upgrade18/`:

- `original/` contains the original data.
- `cluster.sql` contains all databases and role credentials.

Both the directory and its files must remain private. The migration backup is a mandatory step and is not affected by `SKIP_BACKUP_DB`. If the migration is interrupted, the application stays stopped; retrying the same upgrade continues the migration, and a normal start is refused until it completes.

Data created after the business is restored is not written back to the old directory, and the old directory cannot be switched back directly. The space precheck estimates three times the old data size plus 1 GiB. Large objects or highly compressed data may need more space.

Automatic migration requires a verifiable administrator account, standard data paths, and standard configuration. Deployments with custom tablespaces, external configuration or SSL files, logical replication, or non-libc template locale settings abort during the precheck and need a separate migration. The original image and old data are not cleaned up automatically.

## JDMC HA

JDMC HA is coordinated across two nodes: stop business traffic and leader election, migrate the primary database, rebuild the PostgreSQL 18 standby, and verify streaming replication, synchronous commit, and startup write isolation. The installer then updates the application and exits maintenance mode.

Both JDMC nodes must support this migration before it starts. A new full upgrade package declares `maintenance-pg18-v1`; older JDMC versions reject that package so the database migration cannot be skipped. `pg_rewind` does not perform a database major-version migration.

See the PostgreSQL documentation for [upgrading](https://www.postgresql.org/docs/18/upgrading.html) and [primary/standby requirements](https://www.postgresql.org/docs/18/warm-standby.html).
