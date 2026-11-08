# Validation and operations

[Repository overview](../README.md) · [Services](services.md) · [Backups](backups.md) · [Recovery](recovery.md)

Commands below run from the checkout in Bash. On Apollo, enter `bash` from the administrator's Fish shell. Use the pinned lockfile when validating an existing checkout; changing it changes the system being evaluated.

## Local validation

On a machine with Nix and flakes enabled:

```bash
nix fmt
nix flake check --no-build --all-systems
```

`--no-build` evaluates the complete `x86_64-linux` system without building it. [CI](../.github/workflows/check.yml) runs on every push: it scans the Git history for secrets and builds every flake check (the system closure and NixOS VM tests). Its own build results go to the public Cachix cache `mkoppmann-apollo`, so later runs rebuild only what changed. Apollo does not use that cache. Do not deploy a commit whose CI run failed.

## Deployment

Apollo's checkout is `/etc/nixos`. It belongs to the user `deploy`, which has no login: Git runs as `sudo -u deploy git …`, never as root, and changing what root builds still takes the sudo password. Root only reads the checkout when building; read-only Git commands also work as `mcp`. Its `flake.lock` is usually newer than Git's because of [automatic updates](#automatic-updates). Discard it before pulling; the upgrade service updates it again before switching, so inputs never move backwards:

```bash
cd /etc/nixos
sudo -u deploy git checkout -- flake.lock && sudo -u deploy git pull --ff-only
sudo systemctl start nixos-upgrade.service
journalctl -u nixos-upgrade.service -n 100
```

To deploy exactly the lockfile from Git instead, run `sudo nixos-rebuild switch --flake .#apollo`. Never use `path:.#apollo`: a `path:` flake copies untracked files from `/etc/nixos` into the world-readable Nix store.

After activation, check `systemctl --failed` and application logins. A switch may restart Nginx and briefly interrupt every site. A system-generation rollback does not undo application data migrations.

To publish the server's lockfile, copy `/etc/nixos/flake.lock` into the repository and commit it.

## Automatic updates

[Automatic upgrade configuration](../modules/auto-upgrade.nix) schedules `nixos-upgrade` at 00:00, 06:00, 12:00 and 18:00 Europe/Vienna with up to 30 minutes of random delay. Its pre-start runs `nix flake update` for all inputs in `/etc/nixos` as `deploy`, then the service rebuilds and switches without writing to the checkout. The timer is persistent, so a missed run can trigger after boot. Automatic reboot is disabled.

Each run leaves an audit trail in `journalctl -u nixos-upgrade.service`: `nix flake update` lists every changed input revision, and the post-start step prints `nix store diff-closures` between the previous and new system. Major application/database migrations arrive unreviewed this way; there is no automatic data-migration rollback.

## Routine health checks

```bash
systemctl --failed
systemctl list-timers --all
sudo borg-job-sidechest info --last 1
sudo zpool status rpool
findmnt --mountpoint /persist
findmnt --mountpoint /var/log
sudo wg show wg0
```

After a reboot, also check the retained service paths, Fish history and application logins. For Vaultwarden notifications, confirm `/notifications/hub` has a WebSocket 101 handshake in a signed-in client and that a harmless edit reaches another client without manual sync; do not share URLs containing access tokens. WireGuard Internet routing is checked with fresh IPv4 connections from a peer; the photo proxy also depends on peer `10.100.0.2` being reachable.

## WireGuard peers

Peers are declared in the [WireGuard module](../modules/wireguard.nix) as `peerN`, where `N` is the last octet of their tunnel address. Each has a preshared key in sops (`wireguard_psk_peerN`) in addition to its key pair.

To add a peer, create its key pair on the device or with `wg genkey | tee private.key | wg pubkey`, add its public key under the next free name, and store a new preshared key in sops on Apollo, using the host key:

```bash
sudo bash
cd /etc/nixos
psk=$(wg genpsk)
printf %s "$psk" | nix shell nixpkgs#jq -c jq -Rs . \
  | SOPS_AGE_KEY_FILE=/persist/var/lib/sops-nix/key.txt nix shell nixpkgs#sops -c \
    sops set --value-stdin secrets/apollo.yaml '["wireguard_psk_peerN"]'
echo "$psk"   # for the client configuration only
```

Client configuration:

```ini
[Interface]
PrivateKey = …
Address = 10.100.0.N/32
DNS = 10.100.0.1

[Peer]
PublicKey = …                  # sudo wg show wg0 public-key
PresharedKey = …
Endpoint = 152.53.35.165:51820
AllowedIPs = 10.100.0.0/24     # see below
PersistentKeepalive = 25
```

- `AllowedIPs = 10.100.0.0/24` reaches Apollo and its services through the tunnel; Apollo does not forward between peers. `0.0.0.0/0, ::/0` sends all traffic through Apollo; IPv6 is then dropped instead of bypassing the tunnel, because the tunnel carries only IPv4.
- `DNS = 10.100.0.1` is needed for the [admin gate](services.md#applications): only then does `idp.ncrypt.at` resolve to the tunnel address. Pleroma’s admin paths need `AllowedIPs = 0.0.0.0/0, ::/0` instead. Leave it out on servers, whose name resolution would otherwise depend on Apollo.
- Servers that only answer Apollo, such as the photo upstream on `peer2`, use `AllowedIPs = 10.100.0.1/32`, which also drops traffic from other peers.

## Remote unlock

During initrd, connect from an independent administrator machine using the private key matching the declared administrator public key:

```bash
ssh -t -p 2222 -i /PATH/TO/ADMINISTRATOR_KEY root@152.53.35.165 \
  systemd-tty-ask-password-agent --watch
```

Verify the separate initrd host fingerprint and enter the ZFS unlock secret at the password-agent prompt. SSH may disconnect as boot transitions. After boot, SSH is reachable only through WireGuard:

```bash
ssh -i /PATH/TO/ADMINISTRATOR_KEY mcp@10.100.0.1
```

If WireGuard, SSH or unlock is unavailable, use the provider console or rescue environment. The configured password hash does not recover the plaintext sudo password. Disk encryption has no documented bypass; independent backup credentials provide the alternative recovery path.
