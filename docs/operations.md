# Operations

[Repository overview](../README.md) · [Development](development.md) · [Services](services.md) · [Backups](backups.md) · [Recovery](recovery.md)

Commands below run from the checkout in Bash. On Apollo, enter `bash` from the administrator’s Fish shell. Validate changes as described in [development](development.md#validation). Do not deploy a commit whose CI run failed.

## Deployment

Apollo’s checkout is `/etc/nixos`. It belongs to the user `deploy`, which has no login. Git therefore runs as `sudo -u deploy git …`, never as root, and changing what root builds still takes the sudo password. Root only reads the checkout when it builds. Read-only Git commands also work as `mcp`.

The checkout’s `flake.lock` is usually newer than Git’s because of [automatic updates](#automatic-updates). Discard it before you pull. The upgrade service updates it again before it switches, so inputs never move backwards:

```bash
cd /etc/nixos
sudo -u deploy git checkout -- flake.lock && sudo -u deploy git pull --ff-only
sudo systemctl start nixos-upgrade.service
journalctl -u nixos-upgrade.service -n 100
```

`nixos-rebuild` builds from the checkout’s lock file as it is. After a pull, that lock file is Git’s, which is usually older than the system Apollo runs. A build from it moves packages backwards, and Nextcloud refuses to start on data of a newer version. Before you run `nixos-rebuild` directly, for example with `test`, update the same inputs as the upgrade service:

```bash
sudo -u deploy nix flake update nixpkgs nixpkgs-unstable website wtcvss
sudo nixos-rebuild test --flake .#apollo
```

Never use `path:.#apollo`: a `path:` flake copies untracked files from `/etc/nixos` into the world-readable Nix store.

Apply changes to the network, the firewall or SSH with `sudo nixos-rebuild test --flake .#apollo` first, and keep a second session open. After activation, check `systemctl --failed` and application logins. A switch may restart Nginx and briefly interrupt every site. A system-generation rollback does not undo application data migrations.

To publish the server’s lockfile, copy `/etc/nixos/flake.lock` into the repository and commit it. It differs from Git’s only in the automatically updated inputs.

## Automatic updates

[Automatic upgrade configuration](../modules/system/auto-upgrade.nix) schedules `nixos-upgrade` at 00:00, 06:00, 12:00 and 18:00 Europe/Vienna with up to 30 minutes of random delay. Its pre-start runs `nix flake update nixpkgs nixpkgs-unstable website wtcvss` in `/etc/nixos` as `deploy`. The service then rebuilds and switches without writing to the checkout. The other inputs (`authentik-nix`, `sops-nix`, `impermanence` and `disko`) provide NixOS modules, which run as root. They stay at the revisions of Git’s lock file.

The timer is persistent, so a missed run can trigger after boot. `pleroma-prune.service` stops the timer while it runs and starts it again afterwards, which catches up a missed run. Automatic reboot is disabled. `pending-reboot-check.service` mails every Monday while a new kernel, initrd or boot parameters wait for a reboot. A reboot needs the operator for the [remote unlock](#remote-unlock).

To update the pinned inputs:

1. Run `nix flake update authentik-nix sops-nix impermanence disko` in the repository.
2. Read what changed upstream.
3. Commit the lock file.
4. Deploy it after CI passed.

Two checks say when that is due. `pinned-inputs-check.service` mails every Monday while the inputs’ branches have commits that the lock file lacks. The mail lists the newest commit subjects of each input. `authentik-update-check.service` mails every day while authentik-nix offers another Authentik release than the pinned one.

Each run leaves an audit trail in `journalctl -u nixos-upgrade.service`. `nix flake update` lists every changed input revision. The post-start step prints `nix store diff-closures` between the previous and new system. Major application and database migrations arrive unreviewed this way. There is no automatic rollback of a data migration.

CI [checks `main` with the same inputs updated](development.md#validation) about two hours before each run. A mail about a failed scheduled run means that Apollo is about to take, or already runs, a combination that fails a check. Read the run’s log, then `journalctl -u nixos-upgrade.service` and `systemctl --failed` on Apollo.

## DNS

INWX is the registrar and DNS host of the zones `ncrypt.at`, `mkoppmann.at` and `cypherpunk.observer`. [dns/dnsconfig.js](../dns/dnsconfig.js) defines all their records for [DNSControl](https://docs.dnscontrol.org/), which deletes records it doesn’t find there. INWX signs the zones with DNSSEC. Each zone has Apollo’s addresses, and its web hosts are aliases of the zone. The web hosts and addresses come from [dns/hosts.json](../dns/hosts.json). The flake check `dns-hosts` fails while that file differs from the Nginx virtual hosts or Apollo’s addresses.

Run DNSControl from the checkout on the operator’s machine, in a terminal without an agent session. The INWX credentials are in `secrets/dnscontrol.yaml`, which only the admin key decrypts:

```bash
nix develop
read -rsp "Admin key: " SOPS_AGE_KEY && export SOPS_AGE_KEY; echo   # paste from KeePass
creds='!sops decrypt --output-type json secrets/dnscontrol.yaml'
dnscontrol preview --config dns/dnsconfig.js --creds "$creds"
dnscontrol push --config dns/dnsconfig.js --creds "$creds"
unset SOPS_AGE_KEY
```

`preview` lists what `push` would change and changes nothing. Push only from `main`, after the preview shows exactly what the merged commits describe. The CAA records allow certificates only for Apollo’s ACME account, validated over HTTP. The account lives in `/var/lib/acme`. If the account is lost, put the new account’s URI into the records before Nginx requests certificates:

```bash
sudo bash -c 'grep -rho "\"uri\": *\"[^\"]*\"" /var/lib/acme/.lego/accounts'
```

Mail servers only fetch an MTA-STS policy again when the `id` in the domain’s `_mta-sts` record changes. After you change a policy in the [websites module](../modules/services/websites.nix), set the `id` to the current time. Push after the deploy. A new virtual host needs its record before the deploy, because Nginx only gets a certificate for a name that resolves to Apollo.

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

After a reboot, also check the retained service paths, Fish history and application logins.

For Vaultwarden notifications, check two things in a signed-in client. `/notifications/hub` must have a WebSocket 101 handshake. A harmless edit must reach another client without manual sync. Do not share URLs that contain access tokens.

To check WireGuard Internet routing, open fresh IPv4 connections from a peer. The photo proxy also depends on peer `10.100.0.2` being reachable.

## Pleroma administration

`pleroma_ctl` talks to the running node and needs its cookie, which only the `pleroma` user can read:

```bash
sudo -u pleroma sh -c 'RELEASE_COOKIE=$(cat ~/.cookie) pleroma_ctl user list'
```

## WireGuard peers

The [WireGuard module](../modules/system/wireguard.nix) declares peers as `peerN`, where `N` is the last octet of the peer’s tunnel address. Each peer has a preshared key in sops (`wireguard_psk_peerN`) in addition to its key pair.

To add a peer:

1. Create its key pair on the device or with `wg genkey | tee private.key | wg pubkey`.
2. Add its public key under the next free name.
3. Store a new preshared key in sops on Apollo, with the host key, outside the checkout:

```bash
sudo bash
cd /root && umask 077 && cp /etc/nixos/secrets/apollo.yaml .
psk=$(wg genpsk)
printf %s "$psk" | nix shell nixpkgs#sops nixpkgs#jq -c bash -c 'jq -Rs . | SOPS_AGE_KEY_FILE=/persist/var/lib/sops-nix/key.txt sops set --value-stdin apollo.yaml "[\"wireguard_psk_peerN\"]"'
echo "$psk"   # for the client configuration only
install -o mcp -m 644 apollo.yaml /home/mcp/ && rm apollo.yaml
```

Then copy `apollo.yaml` into the checkout as described in [secrets](secrets.md#editing-secrets).

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

- `AllowedIPs = 10.100.0.0/24` reaches Apollo and its services through the tunnel. Apollo does not forward between peers. `0.0.0.0/0, ::/0` sends all traffic through Apollo. The tunnel carries only IPv4, so IPv6 is then dropped instead of bypassing the tunnel.
- The [admin gate](services.md#applications) needs `DNS = 10.100.0.1`: only then does `idp.ncrypt.at` resolve to the tunnel address. Pleroma’s admin paths need `AllowedIPs = 0.0.0.0/0, ::/0` instead. Leave `DNS` out on servers, whose name resolution would otherwise depend on Apollo.
- Servers that only answer Apollo, such as the photo upstream on `peer2`, use `AllowedIPs = 10.100.0.1/32`, which also drops traffic from other peers.

## Remote unlock

During initrd, connect from an independent administrator machine. Use the private key that matches the declared administrator public key:

```bash
ssh -t -p 2222 -i /PATH/TO/ADMINISTRATOR_KEY root@152.53.35.165
```

Verify the separate initrd host fingerprint. Then enter the ZFS unlock secret at the prompt. The key only reaches this prompt in the initrd: it gets no shell and no forwarding. Connect with plain `ssh`. Some terminals have an SSH integration that runs its own command at login, for example to install its terminfo. Such an integration gets no prompt, because the key runs the password agent instead of that command. SSH may disconnect as boot transitions. After boot, SSH is reachable only through WireGuard:

```bash
ssh -i /PATH/TO/ADMINISTRATOR_KEY mcp@10.100.0.1
```

If WireGuard, SSH or unlock is unavailable, use the provider console or rescue environment. The configured password hash does not recover the plaintext sudo password. Disk encryption has no documented bypass. Independent backup credentials provide the alternative recovery path.
