# File and server recovery

[Repository overview](../README.md) · [Storage](storage.md) · [Secrets](secrets.md) · [PostgreSQL restoration](postgresql-restore.md)

This guide follows the configured storage and backup interfaces; it is not a record of a completed restore. Use a compatible Linux recovery environment with root Bash, ZFS, Nix/flakes, Borg 1.x, PostgreSQL 16 clients, rsync with ACL/xattr support and enough encrypted staging capacity. Match the application/configuration versions to the selected backup rather than upgrading during recovery.

## Independent prerequisites

Keep these accessible without Apollo-hosted SSO, email or password storage:

- Provider console/rescue and DNS administration, including account recovery/MFA material.
- Administrator SSH private key, verified normal/initrd host fingerprints and the actual `mcp` sudo password.
- ZFS encryption credentials and a verified disk/partition/pool/dataset inventory.
- Storage Box SSH key and verified port-23 host fingerprint, repository identity, Borg passphrase and an independently exported repository key.
- Repository/lockfile and deployed local changes, application identities/keys and relevant recovery codes.
- End-user encryption material: Vaultwarden master passwords, Matrix recovery keys and Actual budget encryption passwords where used. Server backups do not replace these.

The Borg `repokey-blake2` key normally lives encrypted in the repository. From a configured Borg client, `borg key export "$BORG_REPO" /SECURE_INDEPENDENT_LOCATION/apollo-borg-key` exports that key, not its passphrase or archive data. Do not initialise, repair or break repository locks as a routine recovery step.

The repository lacks the physical storage/encryption creation details. Collect them from an intact host using `lsblk`, `findmnt`, `zpool status -P rpool`, `zfs list -r rpool` and `zfs get -r encryption,encryptionroot,keyformat,keylocation rpool`; retain the inventory privately. Do not force-import a pool that another host might still use.

## Select and extract an archive

Use root Bash with `set -euo pipefail` and `umask 077`. Choose a new private directory on an independently mounted encrypted recovery volume, outside the live restoration destination. These examples require a path without whitespace:

```bash
recovery_case=/recovery/apollo-restore-REPLACE_WITH_CASE_ID
mkdir -m 0700 "$recovery_case"
mkdir -m 0700 "$recovery_case/credentials" "$recovery_case/extracted"
```

Install the independently retained `borg_sidechest_ssh`, `borg_sidechest_passphrase` and verified `known_hosts` into its credentials directory (`0600`). The host-trust entry must cover `[u237324-sub2.your-storagebox.de]:23`; an unverified key scan is not independent trust.

```bash
export BORG_REPO='ssh://u237324-sub2@u237324-sub2.your-storagebox.de:23/home/borg'
export BORG_PASSCOMMAND="cat $recovery_case/credentials/borg_sidechest_passphrase"
export BORG_RSH="ssh -i $recovery_case/credentials/borg_sidechest_ssh -o IdentitiesOnly=yes -o UserKnownHostsFile=$recovery_case/credentials/known_hosts -o StrictHostKeyChecking=yes"
export BORG_CONFIG_DIR="$recovery_case/borg-config"
export BORG_CACHE_DIR="$recovery_case/borg-cache"
export BORG_SECURITY_DIR="$recovery_case/borg-security"
borg --version
borg info "$BORG_REPO"
borg list "$BORG_REPO"
```

On an existing Apollo, acquire the [operation lock](backups.md#state-and-failure-handling) around manual Borg commands and coordinate recovery with scheduled writers. On a separate recovery machine, prevent concurrent repository maintenance by the original host. Verify repository identity and resolve new-client security warnings before proceeding.

Choose an actual archive, inspect its timestamp and contents, then extract into staging rather than over `/`:

```bash
restore_archive=REPLACE_WITH_REVIEWED_ARCHIVE_NAME
borg info "$BORG_REPO::$restore_archive"
borg list "$BORG_REPO::$restore_archive" > "$recovery_case/archive-files.txt"
(
  cd "$recovery_case/extracted"
  borg extract --numeric-ids "$BORG_REPO::$restore_archive" persist var/log
)
```

Confirm the archive actually uses relative `persist` and `var/log` paths. Resolve extraction warnings and preserve the extracted baseline unchanged. Check that each application's files, keys and database export belong to the same selected capture. Missing required material blocks that application's recovery.

Validate the capture manifest and exports before restoration. This read-only example requires Python 3 in the recovery environment:

```bash
python3 - "$recovery_case/extracted/persist/var/backup/postgresql" <<'CHECK'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
manifest = json.loads((root / 'capture.json').read_text())
expected = {name + '.sql' for name in manifest['databases']} | {'globals/globals.sql'}
if set(manifest['files']) != expected:
    raise SystemExit('Manifest export inventory mismatch')
for name, record in manifest['files'].items():
    relative = pathlib.PurePosixPath(name)
    if relative.is_absolute() or '..' in relative.parts:
        raise SystemExit('Invalid export path')
    path = root / relative
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    if path.stat().st_size != record['size'] or digest.hexdigest() != record['sha256']:
        raise SystemExit('Export size/hash mismatch: ' + name)
print('Export hashes match capture', manifest['runId'], manifest['capturedAt'])
CHECK
```

Match that run ID/time and database inventory to the chosen archive and [configured coverage](backups.md#consistency-and-coverage). Hashes and `pg_restore --list` checks detect specific file problems; they do not prove application recovery. If the manifest is unavailable, matching-capture validation cannot be established by this procedure.

## Prepare a replacement

Fence off the original server before reusing its identities. Restrict application ingress and test egress while retaining administrator/provider access. Recreate the independently verified storage layout in rescue; update hardware/network declarations if the replacement differs.

The root rollback requires `rpool/local/root@blank`. On a confirmed empty replacement root dataset, create that snapshot before populating the installation root or restoring children. Never replace an existing baseline with a snapshot of a populated root.

Mount the target root at `/mnt` and the ESP, Nix, persistent and log filesystems at `/mnt/boot`, `/mnt/nix`, `/mnt/persist`, `/mnt/var/log`. Verify each is the intended mounted filesystem. Restore persistent files and logs, preserving metadata, while excluding raw PostgreSQL state, Borg cache and historical random seed even if present in the extracted archive:

```bash
rsync -aHAX --numeric-ids --exclude='/var/lib/postgresql/***' \
  --exclude='/root/.cache/borg/***' --exclude='/var/lib/systemd/random-seed' \
  "$recovery_case/extracted/persist/" /mnt/persist/
rsync -aHAX --numeric-ids "$recovery_case/extracted/var/log/" /mnt/var/log/
```

Restore all boot credentials and explicit identity files before installation. Use the configuration matching the data, with required hardware/network adjustments reviewed. With a successfully evaluated configuration at `/mnt/persist/etc/nixos`, install from a compatible NixOS environment:

```bash
nixos-install --root /mnt --flake /mnt/persist/etc/nixos#apollo --no-root-passwd
```

Confirm initrd-key copying and bootloader installation succeed. Do not copy an arbitrary old ESP or restore the excluded random seed. Before normal boot, establish application isolation; masks written into the disposable root's `/etc` will be lost at rollback.

## Restore and release applications

The repository has no recovery boot mode. One manual isolation method is to append temporary `systemd.mask=UNIT` kernel arguments using the provider console's systemd-boot editor. Prepare the arguments from the unit list below; verify the method on the replacement and reapply remaining masks on every recovery boot:

```bash
recovery_units=(
  timers.target nixos-upgrade.service nginx.service actual.service
  authentik.service authentik-worker.service authentik-migrate.service
  matrix-synapse.service matrix-authentication-service.service synapse-auto-compressor.service
  nextcloud-setup.service nextcloud-update-db.service nextcloud-cron.service
  phpfpm-nextcloud.service nextcloud-notify_push.service nextcloud-notify_push_setup.service
  pleroma.service pleroma-migrations.service vaultwarden.service
  onlyoffice-docservice.service onlyoffice-converter.service rabbitmq.service redis-nextcloud.service
  apollo-backup.service apollo-backup-upload.service apollo-backup-recover.service
  apollo-backup-boot-recovery.service apollo-backup-watchdog.service borgbackup-job-sidechest.service
  apollo-alert-check.service apollo-alert-send.service apollo-alert-failure@.service
  postgresqlBackup-authentik.service postgresqlBackup-matrix-authentication-service.service
  postgresqlBackup-matrix-synapse.service postgresqlBackup-nextcloud.service
  postgresqlBackup-onlyoffice.service postgresqlBackup-pleroma.service
  postgresqlBackup-vaultwarden.service postgresql-globals-backup.service
)
printf 'systemd.mask=%s ' "${recovery_units[@]}"
printf '\n'
```

Retain existing boot arguments. Confirm the provider console accepts the complete line. After unlock/boot, inspect `/proc/cmdline`, the listed units' load/active states, timers and actual persistence mounts. All held services must be inactive; stop recovery if isolation is ineffective. PostgreSQL may run to provision the fresh cluster. Remount the encrypted staging volume and reestablish shell variables before continuing.

Keep writers stopped while checking file ownership and [dynamic-user access](secrets.md#provisioning-and-access), then restore [PostgreSQL globals and databases](postgresql-restore.md). Do not start an application just to create directories or users: setup can migrate or overwrite data.

Release successive groups through later boots with only the appropriate masks removed: shared dependencies and controlled Nginx/ACME, Authentik, Matrix/MAS, then other applications. Verify logins, media/files, SMTP and cross-service shared secrets privately. **Keep OnlyOffice held until its table-resetting startup behavior and inconsistent capture boundary have been assessed for the recovered data.** Preserve its extracted database, broker and working files before any start.

Kernel-command-line masks are recreated for that boot; remove them from subsequent boot arguments rather than relying on `systemctl unmask`. Keep backup, update and scheduled writer units held until restored application data is accepted. Then verify normal timer schedules, a new production backup/upload and alert delivery. Missing local backup-success evidence remains unknown until a new production upload; do not fabricate it to clear alerts.

## Targeted restoration on Apollo

Before overwriting an application's current state, use a quiet window to stop automatic updates and capture/upload scheduling, create a backup deployment hold, and wait for existing work/recovery to finish as described in [operations](operations.md#manual-deployment). Prevent access to the affected application; stop and temporarily mask its server, workers, background-job timers and migration/setup units. Reestablish isolation after any reboot and remove only masks introduced for this recovery. Shared services may have other consumers; do not stop them indiscriminately.

Preserve a private copy of the application's current files, secrets, database export, relevant globals and configuration before changing anything. Store that copy outside the destination and ensure it survives reboot. Restore only the chosen application's matching file/database set from staging; avoid replaying cluster-wide globals over unrelated users. Keep it stopped after an error, preserving diagnostics and the unchanged source copy.

Verify application behavior and dependencies before restoring access or scheduling. A system-generation rollback cannot reverse database/file changes; use the preserved application copy if data recovery must be reversed.
