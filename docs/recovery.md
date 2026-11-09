# File and server recovery

[Repository overview](../README.md) · [Storage](storage.md) · [Secrets](secrets.md) · [Backups](backups.md) · [PostgreSQL restoration](postgresql-restore.md)

## Independent prerequisites

Keep these accessible without Apollo, its SSO, mail or password manager hosting:

- Provider console and rescue access, DNS administration and their recovery codes.
- The administrator SSH key, the `mcp` sudo password and the ZFS passphrase.
- The sops admin key (KeePass) and, ideally, the sops host key.
- The Borg passphrase, the Storage Box SSH key or login, and the exported Borg repository key (`sudo borg-job-sidechest key export`).
- End-user material that server backups do not replace: Vaultwarden master passwords, Matrix recovery keys, Actual budget passwords.

The Borg passphrase and SSH key are also in sops, but decrypting sops needs a working server key; keep the KeePass copies.

## Recent mistakes: local snapshots

For files changed or deleted within the last week, copy them back from Sanoid’s snapshots, for example:

```bash
ls /persist/.zfs/snapshot/
sudo cp -a /persist/.zfs/snapshot/autosnap_DATE_hourly/var/lib/nextcloud/data/USER/files/FILE /var/lib/nextcloud/data/USER/files/
```

Databases cannot be restored this way; use the dumps below.

## Extract an archive

On Apollo the job’s wrapper already knows the repository and credentials. Elsewhere, install the Storage Box host key from the [backup module](../modules/backup.nix) into `known_hosts` and set the environment by hand:

```bash
umask 077
export BORG_REPO='ssh://u237324-sub2@u237324-sub2.your-storagebox.de:23/home/borg'
export BORG_PASSCOMMAND='cat /PATH/TO/borg_passphrase'
export BORG_RSH='ssh -i /PATH/TO/borg_ssh_key'
borg list
```

Extract into an empty directory on an encrypted volume, never over `/`:

```bash
mkdir -m 0700 /recovery && cd /recovery
borg extract --numeric-ids ::apollo-sidechest-DATE persist var/log
```

If the repository’s key is damaged, `borg key import` restores it from the exported copy.

## Restore one application on Apollo

1. Stop the application, its workers and timers, and `nixos-upgrade.timer`.
2. Keep a copy of its current files and a fresh `pg_dump` of its database.
3. Copy its files from `/recovery/persist/…` back with their ownership (`rsync -aHAX --numeric-ids`).
4. Restore its database from `/recovery/persist/var/backup/postgresql/NAME.sql`; see [PostgreSQL restoration](postgresql-restore.md).
5. Start it again and check logins and data. For Nextcloud, run `occ files:scan --all`.

## Rebuild on a new server

1. Fence off the old server so it cannot run with the same identities.
2. In the rescue system, recreate the pool layout: an encrypted `rpool` with `local/root` (snapshot `local/root@blank` while empty), `local/nix`, `safe/persist` and `safe/log`, and the ESP. Adjust `hardware-configuration.nix` and the network settings if the hardware differs.
3. Mount the target at `/mnt` (with `/mnt/boot`, `/mnt/nix`, `/mnt/persist`, `/mnt/var/log`), extract the archive and copy it into place, leaving out the live database and the random seed:

   ```bash
   rsync -aHAX --numeric-ids --exclude='/var/lib/postgresql/***' \
     --exclude='/var/lib/systemd/random-seed' /recovery/persist/ /mnt/persist/
   rsync -aHAX --numeric-ids /recovery/var/log/ /mnt/var/log/
   ```

   This restores the SSH host keys, the initrd host key in `/persist/credentials`, the sops host key and the checkout in `/persist/etc/nixos`.
4. Install. The checkout belongs to `deploy`, and Nix refuses a repository owned by another user unless it is marked safe:

   ```bash
   git config --global --add safe.directory /mnt/persist/etc/nixos
   nixos-install --root /mnt --flake /mnt/persist/etc/nixos#apollo --no-root-passwd
   ```
5. Boot with the applications held back, so that none of them initialises an empty database: append `systemd.mask=UNIT` arguments for `nginx.service`, the application services and `timers.target` in the boot menu. PostgreSQL may run.
6. Restore the globals and databases as in [PostgreSQL restoration](postgresql-restore.md).
7. Boot without the masks, check every application and run `sudo systemctl start borgbackup-job-sidechest.service` to confirm backups work from the new server.
