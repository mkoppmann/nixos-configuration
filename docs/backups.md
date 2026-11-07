# Backup operation

[Repository overview](../README.md) · [Storage](storage.md) · [Alerts](alerts.md) · [Recovery](recovery.md)

[Host configuration](../configuration.nix) supplies Borg settings. The [orchestration module](../modules/backup-orchestration.nix) and [coordinator](../scripts/backup-orchestration.py) control capture, upload and recovery; [PostgreSQL configuration](../modules/postgresql.nix) selects database exports.

## Schedule and lifecycle

| Unit | Purpose |
| --- | --- |
| `apollo-backup.timer` / `.service` | Capture at 03:00 Europe/Vienna; resume applications; request upload on success |
| `apollo-backup-upload.timer` / `.service` | Hourly upload-only retry of a retained capture |
| `apollo-backup-watchdog.timer` / `.service` | One-second maintenance guard; retained-snapshot space checks at most once a minute |
| `apollo-backup-recover.service` | Resume applications and timers after interrupted maintenance |
| `apollo-backup-boot-recovery.service` | Reconcile interrupted work at boot |
| `borgbackup-job-sidechest.service` | Compatibility entrypoint forwarding to the snapshot uploader |

Capture and upload timers have no missed-run catch-up. Database/globals services and the original Borg job have no independent timers. Boot recovery does not create a new capture or immediately upload one.

The capture workflow:

1. Check pool space, dataset/mount layout, PostgreSQL readiness, selected/live database inventory and pending writers/migrations. Unexpected descendant datasets or nested mounts beneath the two snapshot sources cause failure.
2. Block new covered application/job starts and pause their timers. Drain Nextcloud cron and the Synapse compressor, then show HTTP maintenance responses and stop covered applications cleanly.
3. Export every selected database and PostgreSQL globals into private staging. Validate nonempty outputs and custom-format parsing, compute hashes, publish final exports and `capture.json`, then snapshot `rpool/safe/persist` and `rpool/safe/log` with one run identifier.
4. Resume applications/timers and check service/listener readiness. Upload from read-only snapshot views after applications resume; verify dump hashes again before Borg runs.

Capture has a 480-second budget, with work cut off at 475 seconds to allow cancellation; resumption has a further 120 seconds. The independent watchdog and recovery service handle interruption. At the 600-second maintenance boundary synthetic HTTP/start barriers are removed, while real service failures remain visible and recovery continues trying to restore availability.

## Consistency and coverage

Covered applications are Actual, Authentik server/worker, Synapse, MAS, Nextcloud PHP-FPM/notify-push, Pleroma and Vaultwarden. Their migration/setup units are checked and held back during capture. Covered hosts return 503 during the application pause; ACME challenge paths and unrelated sites remain available.

PostgreSQL, Redis and Nginx remain running. Other unpaused host state and logs have filesystem-snapshot consistency. Actual's SQLite files are captured with its server stopped.

| PostgreSQL database / owning role | Export beneath `/var/backup/postgresql` |
| --- | --- |
| `authentik` | `authentik.sql` |
| `matrix-authentication-service` | `matrix-authentication-service.sql` |
| `matrix-synapse` | `matrix-synapse.sql` |
| `nextcloud` | `nextcloud.sql` |
| `pleroma` | `pleroma.sql` |
| `vaultwarden` | `vaultwarden.sql` |

Selection uses the unique merged `services.postgresql.ensureDatabases`. Assertions reject disabled backups, `backupAll` mode or missing declared databases. Adding a database does not automatically identify its application writers, listeners, maintenance hosts or persistent files; those lists are explicit in the orchestration module.

Despite their `.sql` suffix, application exports are custom-format **`pg_restore` archives**. Coordinated exports disable internal compression; Borg compresses during upload. `globals/globals.sql` is **plain SQL for `psql`**, including role password hashes, memberships, attributes and tablespace definitions. It does not supply extension binaries or tablespace directories. See [PostgreSQL restoration](postgresql-restore.md).

The capture manifest at `persist/var/backup/postgresql/capture.json` identifies the run, databases, export sizes/hashes and consistency exceptions. Exports are private (`0600`, in `postgres:postgres 0700` directories). Previous successful versions use `.prev.sql`; `.in-progress.sql` files are incomplete. Manual `postgresqlBackup-NAME.service` and `postgresql-globals-backup.service` exports share the operation lock but do not establish a coordinated application capture. The per-database manual job can move the last final file to `.prev.sql` before a failing export; inspect both names.

## Borg repository and exclusions

| Setting | Value |
| --- | --- |
| Job / successful archive prefix | `sidechest` / `apollo-sidechest-` |
| Repository | `ssh://u237324-sub2@u237324-sub2.your-storagebox.de:23/home/borg` |
| Encryption / compression | `repokey-blake2` / `auto,zstd` |
| Retention | 7 daily, 4 weekly, 6 monthly archives matching this job's prefix |
| Source paths within archives | Relative `persist` and `var/log` |
| Credentials | [Borg passphrase and SSH key](secrets.md#credential-inventory) |

No automatic repository initialisation is performed. Upload warnings are failures. Failed uploads retain one snapshot set for hourly retries with the original capture timestamp/name. Archive creation, pruning and compaction are recorded separately; retrying retention does not create a second successful archive. Incomplete attempts use a separate reusable name outside the successful retention prefix.

Configured exclusions:

```text
/persist/var/lib/postgresql
/persist/root/.cache/borg
/persist/var/lib/systemd/random-seed
/var/log/audit/audit.log
/var/log/journal/e538f1c97e5f472581a47d4a0acd816c/system.journal
/var/log/nginx/access.log
```

The uploader additionally excludes `/persist/var/lib/apollo-backup`, `.zfs` traversal, private capture/publication staging and in-progress SQL files. Other rotated logs may remain included. Archives do not preserve ZFS layout/properties/snapshots, the EFI partition, Nix store or external photo-server data. A successful archive upload is not proof of archive integrity or application restoration; no recurring Borg integrity-check or restore exercise is configured.

## State and failure handling

`/persist/var/lib/apollo-backup` is `root:root 0700`. `run.json` holds the current ledger and `last-run.json` the preceding run. `last-success.json` records the latest confirmed production upload and its original capture time, independently of later runs; [freshness alerts](alerts.md#health-policy) use that capture time. Retention failure can coexist with a successful uploaded archive. This directory is excluded from Borg, so replacement-host freshness evidence remains unknown until a production upload is recorded.

`/run/apollo-backup` holds transient locks, barriers and private snapshot views. Capture, upload and manual dump services share `operation.lock`; recovery also uses a separate lock. Do not unlink locks, edit the ledger or remove maintenance barriers to bypass a failure. Cleanup acts only on exact snapshot names with matching ownership properties. The next capture retires the previous local snapshot set. Below 10% free pool capacity, captures are refused and retained owned captures can be discarded to recover space.

Run these commands as an operator on Apollo:

```bash
sudo apollo-backup status
sudo apollo-backup preflight
sudo apollo-backup check-resumed
sudo journalctl -u apollo-backup.service -u apollo-backup-upload.service \
  -u apollo-backup-recover.service --since '1 day ago'
```

To request work explicitly, use systemd supervision:

```bash
# Starts a capture and briefly pauses covered applications.
sudo systemctl start apollo-backup.service
# Retries the retained capture without taking another capture.
sudo systemctl start apollo-backup-upload.service
# Retries unfinished application resumption.
sudo systemctl start apollo-backup-recover.service
```

The raw capture/upload/recover CLI commands require systemd's invocation context. `apollo-backup-status` and `apollo-backup-preflight` are aliases for the corresponding subcommands. The raw `borg-job-sidechest` wrapper uses configured credentials but does not acquire the coordinator's lock; wrap administrative access, for example:

```bash
sudo flock --exclusive --nonblock /run/apollo-backup/operation.lock \
  borg-job-sidechest list
```

A root-owned `deployment-hold` file in the ledger directory gates new capture/upload service starts. It does not stop work already running, disable watchdog/recovery, or suppress freshness alerts. See [manual deployment](operations.md#manual-deployment). `apollo-backup-verify` provides explicit supervised failure scenarios; it is not scheduled and its tests can pause real applications, so it is not a routine health probe.
