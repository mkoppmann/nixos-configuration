# Validation and operations

[Repository overview](../README.md) · [Services](services.md) · [Backups](backups.md) · [Recovery](recovery.md)

Commands below run from the checkout in Bash. On Apollo, enter `bash` from the administrator's Fish shell. Use the pinned lockfile when validating an existing checkout; changing it changes the system being evaluated.

## Local validation

On a machine with Nix and flakes enabled:

```bash
nix fmt
nix flake check --no-build --all-systems
python3 -m unittest discover -s tests -p 'test_*.py'
```

`--no-build` evaluates the complete `x86_64-linux` system without building it. [CI](../.github/workflows/check.yml) runs on every push: it scans the Git history for secrets, runs the Python tests and builds every flake check (the system closure and NixOS VM tests). Do not deploy a commit whose CI run failed.

## Deployment

Apollo's checkout is `/etc/nixos`. Its `flake.lock` is usually newer than Git's because of [automatic updates](#automatic-updates). Discard it before pulling; the upgrade service updates it again before switching, so inputs never move backwards:

```bash
cd /etc/nixos
sudo git checkout -- flake.lock && sudo git pull --ff-only
sudo systemctl start nixos-upgrade.service
journalctl -u nixos-upgrade.service -n 100
```

To deploy exactly the lockfile from Git instead, run `sudo nixos-rebuild switch --flake .#apollo`. Never use `path:.#apollo`: a `path:` flake copies untracked files from `/etc/nixos` into the world-readable Nix store.

Until the coordinated backup is replaced, avoid deploying while `apollo-backup.service` is active (daily capture at 03:00). After activation, check `systemctl --failed` and application logins. A switch may restart Nginx and briefly interrupt every site. A system-generation rollback does not undo application data migrations.

To publish the server's lockfile, copy `/etc/nixos/flake.lock` into the repository and commit it.

## Automatic updates

[Automatic upgrade configuration](../modules/auto-upgrade.nix) schedules `nixos-upgrade` at 00:00, 06:00, 12:00 and 18:00 Europe/Vienna with up to 30 minutes of random delay. Its pre-start runs `nix flake update` for all inputs in `/etc/nixos`, then the service rebuilds and switches. The timer is persistent, so a missed run can trigger after boot. Automatic reboot is disabled.

Each run leaves an audit trail in `journalctl -u nixos-upgrade.service`: `nix flake update` lists every changed input revision, and the post-start step prints `nix store diff-closures` between the previous and new system. Major application/database migrations arrive unreviewed this way; there is no automatic data-migration rollback.

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
