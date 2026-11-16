# File and server recovery

[Repository overview](../README.md) · [Storage](storage.md) · [Secrets](secrets.md) · [Backups](backups.md) · [PostgreSQL restoration](postgresql-restore.md)

## Independent prerequisites

Keep these accessible without Apollo, its SSO, mail or password manager hosting:

- Provider console and rescue access, DNS administration and their recovery codes.
- The administrator SSH key, the `mcp` sudo password and the ZFS passphrase.
- The sops admin key (KeePass) and, ideally, the sops host key.
- The Borg passphrase, the Storage Box SSH key or login, and the exported Borg repository key (`sudo borg-job-sidechest key export`).
- End-user material that server backups do not replace: Vaultwarden master passwords, Matrix recovery keys, Actual budget passwords.

The Borg passphrase and SSH key are also in sops, but decrypting sops needs the admin key or the host key. Keep the KeePass copies.

## Recent mistakes: local snapshots

To recover files changed or deleted within the last week, copy them back from Sanoid’s snapshots, for example:

```bash
ls /persist/.zfs/snapshot/
sudo cp -a /persist/.zfs/snapshot/autosnap_DATE_hourly/var/lib/nextcloud/data/USER/files/FILE /var/lib/nextcloud/data/USER/files/
```

Databases cannot be restored this way. Use the dumps below.

## Extract an archive

On Apollo the job’s wrapper already knows the repository and credentials. Elsewhere, install the Storage Box host key from the [backup module](../modules/system/backup.nix) into `known_hosts`. Then set the environment by hand:

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
2. Keep a copy of its current files and a fresh `pg_dump --format=custom` of its database.
3. Copy its files from `/recovery/persist/…` back with their ownership (`rsync -aHAX --numeric-ids`).
4. Restore its database from `/recovery/persist/var/backup/postgresql/NAME.sql`, as in [PostgreSQL restoration](postgresql-restore.md).
5. Start the application again and check logins and data. For Nextcloud, run `occ files:scan --all`.

## Rebuild on a new server

1. Fence off the old server so it cannot run with the same identities.
2. In the rescue system, recreate the layout from the [storage configuration](../modules/system/storage.nix). Adjust the disk device there, `hardware-configuration.nix` and the network settings if the hardware differs.
3. Mount the target at `/mnt` (with `/mnt/boot`, `/mnt/nix`, `/mnt/persist`, `/mnt/var/log`). Extract the archive and copy it into place without the live database:

   ```bash
   rsync -aHAX --numeric-ids --exclude='/var/lib/postgresql/***' \
     /recovery/persist/ /mnt/persist/
   rsync -aHAX --numeric-ids /recovery/var/log/ /mnt/var/log/
   ```

   This restores the SSH host keys, the initrd host key in `/persist/credentials`, the sops host key and the checkout in `/persist/etc/nixos`.
4. Install. The checkout belongs to `deploy`, and Nix refuses a repository owned by another user unless it is marked safe:

   ```bash
   git config --global --add safe.directory /mnt/persist/etc/nixos
   nixos-install --root /mnt --flake /mnt/persist/etc/nixos#apollo --no-root-passwd
   ```
5. Boot with the applications held back, so that none of them initialises an empty database. In the boot menu, append `systemd.mask=UNIT` arguments for `nginx.service`, the application services and `timers.target`. PostgreSQL may run.
6. Restore the globals and databases as in [PostgreSQL restoration](postgresql-restore.md).
7. Boot without the masks and check every application. Run `sudo systemctl start borgbackup-job-sidechest.service` to check that backups work from the new server.
