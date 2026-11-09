# Backups

[Repository overview](../README.md) · [Storage](storage.md) · [Monitoring](monitoring.md) · [Recovery](recovery.md)

The [backup module](../modules/backup.nix) uses the upstream `services.borgbackup` job `sidechest`; [PostgreSQL configuration](../modules/postgresql.nix) defines the database dumps.

## Nightly run

`borgbackup-job-sidechest.timer` starts the job at 03:00 Europe/Vienna; a run missed while Apollo was down starts after boot. Applications keep running. The job:

1. Dumps every database declared in `services.postgresql.ensureDatabases` to `/var/backup/postgresql/NAME.sql` (custom format for `pg_restore`, despite the suffix) and the roles to `globals/globals.sql` (plain SQL for `psql`). The previous dump of each database is kept as `NAME.prev.sql`.
2. Snapshots `rpool/safe/persist` and `rpool/safe/log` in one atomic `zfs snapshot` and mounts both read-only inside the unit’s private mount namespace.
3. Archives the snapshots as `persist/…` and `var/log/…`, prunes and compacts.
4. Unmounts and destroys the snapshots, also after a failure.

Each dump is transactionally consistent. Application files are crash-consistent as of the snapshot, a few seconds after the dumps; a file written in between can exist without its database row or the other way round. For Nextcloud, `occ files:scan --all` reconciles this after a restore.

## Repository

| Setting | Value |
| --- | --- |
| Repository | `ssh://u237324-sub2@u237324-sub2.your-storagebox.de:23/home/borg` |
| Encryption / compression | `repokey-blake2` / `auto,zstd` |
| Archive names | `apollo-sidechest-DATE` |
| Retention | 7 daily, 4 weekly, 6 monthly |
| Credentials | sops secrets `borg_passphrase` and `borg_ssh_key` |
| Excluded | `persist/var/lib/postgresql` (the dumps cover it), `persist/root/.cache/borg`, `persist/var/lib/systemd/random-seed`, `var/log/nginx/access.log` |

Archives do not contain the Nix store, the ESP, ZFS properties or the photo server’s data. The Storage Box keeps its own snapshots of the repository. The repository key is exported to KeePass; see [recovery](recovery.md#independent-prerequisites).

`borgbackup-check-sidechest.timer` runs `borg check --verify-data --last 1` on the first of every month: it checks the repository’s consistency on the Storage Box and reads back all data of the latest archive.

## Local snapshots

Sanoid keeps 24 hourly and 7 daily snapshots of `rpool/safe/persist`. To recover a file deleted or changed in the last week, copy it from `/persist/.zfs/snapshot/autosnap_…/`. Local snapshots share the pool with the data and are no backup.

## Operations

```bash
# Run a backup now.
sudo systemctl start borgbackup-job-sidechest.service
journalctl -u borgbackup-job-sidechest.service --since '1 day ago'
# The wrapper sets the repository, passphrase and SSH key.
sudo borg-job-sidechest list
sudo borg-job-sidechest info --last 1
zfs list -t snapshot rpool/safe/persist
```

Failures send a mail like every failed unit; a missing success ping alerts through healthchecks.io. See [monitoring](monitoring.md).
