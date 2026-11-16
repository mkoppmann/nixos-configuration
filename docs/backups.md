# Backups

[Repository overview](../README.md) · [Storage](storage.md) · [Monitoring](monitoring.md) · [Recovery](recovery.md)

The [backup module](../modules/system/backup.nix) uses the upstream `services.borgbackup` job `sidechest`. [PostgreSQL configuration](../modules/services/postgresql.nix) defines the database dumps.

## Nightly run

`borgbackup-job-sidechest.timer` starts the job at 03:00 Europe/Vienna. If Apollo was down at that time, the job starts after boot. Applications keep running. The job:

1. Dumps every database declared in `services.postgresql.ensureDatabases` to `/var/backup/postgresql/NAME.sql`. The dumps use the custom format for `pg_restore`, despite the suffix. The job dumps the roles to `globals/globals.sql` as plain SQL for `psql`. The dumps are uncompressed, so Borg only stores what changed since the previous night and compresses it itself.
2. Snapshots `rpool/safe/persist` and `rpool/safe/log` in one atomic `zfs snapshot` and mounts both read-only inside the unit’s private mount namespace.
3. Archives the snapshots as `persist/…` and `var/log/…`, prunes and compacts.
4. Unmounts and destroys the snapshots and deletes the dumps, also after a failure. The local snapshots taken during the run keep that night’s dumps for a day.

Each dump is transactionally consistent. Application files are crash-consistent as of the snapshot, a few seconds after the dumps. A file written in between can exist without its database row, or the other way round. For Nextcloud, `occ files:scan --all` reconciles this after a restore.

## Repository

| Setting | Value |
| --- | --- |
| Repository | `ssh://u237324-sub2@u237324-sub2.your-storagebox.de:23/home/borg` |
| Encryption / compression | `repokey-blake2` / `auto,zstd` |
| Archive names | `apollo-sidechest-DATE` |
| Retention | 7 daily, 4 weekly, 6 monthly |
| Credentials | sops secrets `borg_passphrase` and `borg_ssh_key` |
| Excluded | `persist/var/lib/postgresql` (the dumps cover it), `persist/root/.cache/borg` |

Archives do not contain the Nix store, the ESP, ZFS properties or the photo server’s data. The Storage Box keeps its own snapshots of the repository. KeePass holds an export of the repository key, as [recovery](recovery.md#independent-prerequisites) describes.

`borgbackup-check-sidechest.timer` runs `borg check --verify-data --last 1` on the first of every month. The check covers three things:

- The repository’s consistency on the Storage Box.
- Every chunk of the repository, which the check reads back and verifies, not only the chunks of the latest archive.
- The latest archive’s metadata.

## Local snapshots

Sanoid keeps 24 hourly and 7 daily snapshots of `rpool/safe/persist`, which includes the live PostgreSQL cluster. To recover a file deleted or changed in the last week, copy it from `/persist/.zfs/snapshot/autosnap_…/`. Local snapshots share the pool with the data and are no backup.

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

A failure sends a mail, like every failed service. A missing success ping alerts through healthchecks.io. [Monitoring](monitoring.md) describes both.
