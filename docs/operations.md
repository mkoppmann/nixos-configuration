# Validation and operations

[Repository overview](../README.md) · [Services](services.md) · [Backups](backups.md) · [Recovery](recovery.md)

Commands below run from the checkout in Bash. On Apollo, enter `bash` from the administrator's Fish shell. Use the pinned lockfile when validating an existing checkout; changing it changes the system being evaluated.

## Local validation

Python tests use temporary files and stubbed system commands/SMTP; they require no production secrets or server:

```bash
python3 -m unittest discover -s tests -p 'test_*.py'
```

On a machine with Nix, evaluate the four existing checks without updating the lockfile:

```bash
(
  for check in postgresql-backup persistence backup-orchestration alerts; do
    nix eval --impure --no-update-lock-file --no-write-lock-file \
      --json --file "tests/$check.nix" || exit
  done
)
```

Require every check to succeed; stop at the first failure. The checks force evaluation of the NixOS system and assert database coverage, persistence mappings, orchestration and alert wiring. A `path:` flake is used internally so untracked working-tree files are included. Evaluation can fetch locked inputs and is distinct from a build or live verification.

Build on a suitable Linux builder before activation:

```bash
nix build --no-update-lock-file --no-write-lock-file \
  'path:.#nixosConfigurations.apollo.config.system.build.toplevel'
```

The result is an `x86_64-linux` system. A local macOS machine needs a suitable remote builder to build it. The flake does not export a `checks` set; `nix flake check` alone does not replace these explicit evaluation files.

## Manual deployment

Apollo's deployment checkout is `/etc/nixos`. Review its status, diff and lockfile before a whole-system switch; application setup/migration units can run during activation. Coordinate changes with automatic updates and backup maintenance.

For a quiet maintenance window, first check for existing holds or masks and preserve their intended state. The sequence below assumes no existing backup hold or upgrade masks. Stop new scheduled work, temporarily mask automatic upgrades across activation, and create the backup hold:

```bash
sudo systemctl stop nixos-upgrade.timer apollo-backup.timer apollo-backup-upload.timer
sudo systemctl mask --runtime nixos-upgrade.service nixos-upgrade.timer
sudo install -o root -g root -m 0600 /dev/null \
  /persist/var/lib/apollo-backup/deployment-hold
systemctl show nixos-upgrade.service apollo-backup.service \
  apollo-backup-upload.service apollo-backup-recover.service \
  --property=Id --property=ActiveState --property=SubState
sudo apollo-backup check-resumed
```

The hold and masks do not cancel work already running. Wait for active work and pending recovery to finish, and investigate failed units before proceeding. Do not stop the watchdog or interrupt an active system update. Keep independent SSH/console access available. Runtime masks disappear on reboot; reestablish maintenance isolation if the window spans a reboot.

After successful evaluation, on Apollo:

```bash
cd /etc/nixos
sudo nixos-rebuild build --flake 'path:.#apollo' --no-update-lock-file
nix store diff-closures /run/current-system ./result
# After reviewing the candidate and expected application migrations:
sudo nixos-rebuild switch --flake 'path:.#apollo' --no-update-lock-file
```

Inspect failed units, application health and journals after activation. A system switch may restart shared Nginx and interrupt every proxied site. Persistence-layout changes need data preparation before new mounts hide existing runtime files; boot-only changes need a planned reboot. Root rollback does not undo changes to persistent application files or databases. A system-generation rollback likewise does not undo data migrations.

When maintenance is complete, remove only the hold and masks created for this window and restore the timers to their previous intended state. For the normal enabled schedules:

```bash
sudo apollo-backup check-resumed
sudo rm -- /persist/var/lib/apollo-backup/deployment-hold
sudo systemctl unmask --runtime nixos-upgrade.service nixos-upgrade.timer
sudo systemctl start apollo-backup.timer apollo-backup-upload.timer nixos-upgrade.timer
systemctl list-timers --all
```

Activation may start enabled backup timers again; the hold continues to gate captures/uploads until removed. The upgrade masks prevent scheduled input updates during the switch. Avoid concurrent deployments throughout the window.

## Automatic updates

[Automatic upgrade configuration](../modules/auto-upgrade.nix) schedules `nixos-upgrade` at 00:00, 06:00, 12:00 and 18:00 Europe/Vienna with up to 30 minutes of random delay. Its pre-start runs `nix flake update` in `/etc/nixos`, then the NixOS upgrade service rebuilds and switches to the flake configuration. The timer is persistent, so a missed run can trigger after boot or when the timer is started again. The setting `upgrade = false` disables the rebuild command's own input-update step; it does not disable the explicit pre-start update. Automatic reboot is disabled.

The lockfile on the deployment host can therefore diverge from the Git checkout. Inspect the deployment diff and `journalctl -u nixos-upgrade.service` when comparing repository and running state. Major application/database migrations require review; the configuration does not provide an automatic data-migration rollback.

## Routine health checks

```bash
systemctl --failed
systemctl list-timers --all
sudo apollo-backup status
sudo apollo-backup check-resumed
sudo apollo-alert status
sudo zpool status rpool
findmnt --mountpoint /persist
findmnt --mountpoint /var/log
sudo wg show wg0
```

After a reboot, also check the retained service paths, Fish history and application logins. For Vaultwarden notifications, confirm `/notifications/hub` has a WebSocket 101 handshake in a signed-in client and that a harmless edit reaches another client without manual sync; do not share URLs containing access tokens. WireGuard Internet routing is checked with fresh IPv4 connections from a peer; the photo proxy also depends on peer `10.100.0.2` being reachable.

## Remote unlock

During initrd, connect from an independent administrator machine using the private key matching the declared administrator public key:

```bash
ssh -t -p 2222 -i /PATH/TO/ADMINISTRATOR_KEY root@152.53.35.165 \
  systemd-tty-ask-password-agent --watch
```

Verify the separate initrd host fingerprint and enter the ZFS unlock secret at the password-agent prompt. SSH may disconnect as boot transitions. After boot, normal access is:

```bash
ssh -p 22 -i /PATH/TO/ADMINISTRATOR_KEY mcp@152.53.35.165
```

If SSH/unlock is unavailable, use the provider console or rescue environment. The configured password hash does not recover the plaintext sudo password. Disk encryption has no documented bypass; independent backup credentials provide the alternative recovery path.
