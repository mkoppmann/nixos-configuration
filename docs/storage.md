# Storage and persistent state

[Repository overview](../README.md) · [Secrets](secrets.md) · [Backups](backups.md) · [Recovery](recovery.md)

Storage is declared in [hardware configuration](../hardware-configuration.nix), [boot configuration](../modules/boot.nix) and [persistence configuration](../modules/impermanence.nix); each [service module](../modules/) declares its own retained paths. The repository defines mounts and retained paths; it does not define disk partition sizes, pool/vdev creation, encryption roots or encryption-key storage.

## Filesystems and boot

| Mount | Device | Role |
| --- | --- | --- |
| `/` | `rpool/local/root` | Disposable root; rolled back to `rpool/local/root@blank` in initrd |
| `/nix` | `rpool/local/nix` | Persistent Nix store |
| `/persist` | `rpool/safe/persist` | Persistent backing tree and credentials; needed for boot |
| `/var/log` | `rpool/safe/log` | Separate persistent logs; needed for boot |
| `/boot` | FAT filesystem UUID `9CEC-3C03` | EFI system partition; `umask=0077` |

The ZFS mounts use `noatime`. The ZFS host ID is `e538f1c9`; forced root-pool import is disabled and encryption credentials are requested during boot. There is no disk swap declaration; zram swap is enabled.

`zfs-rollback.service` runs `zfs rollback -r "rpool/local/root@blank"` after pool import and before `sysroot.mount`. The snapshot must already exist. The unit has no explicit failure-reporting or recovery hook. The repository does not establish the behavior of a failed rollback on the running host.

## Retained paths

Impermanence binds the following directory trees to corresponding paths under `/persist`. `hideMounts` marks them with `x-gvfs-hide` for graphical file managers; tools such as `findmnt` still show them. For example, `/var/lib/nextcloud` is backed by `/persist/var/lib/nextcloud`.

| Runtime paths | Contents |
| --- | --- |
| `/etc/nixos` | Deployment checkout |
| `/root/.config/borg`, `/root/.cache/borg` | Borg configuration/security metadata and rebuildable cache; directories `0700` |
| `/srv/www` | Mutable static websites |
| `/var/backup` | PostgreSQL dumps, globals and capture manifest |
| `/var/lib/acme` | ACME accounts and certificates |
| `/var/lib/bitwarden_rs` | Vaultwarden data and environment file |
| `/var/lib/logrotate` | Rotation history at `status`; directory `0700` |
| `/var/lib/matrix-synapse` | Synapse media, keys and secrets |
| `/var/lib/nextcloud` | Nextcloud files, configuration and secrets |
| `/var/lib/nixos` | NixOS account mappings and other module state |
| `/var/lib/pleroma` | Pleroma uploads, static files and secrets |
| `/var/lib/postgresql` | Live PostgreSQL cluster; excluded from Borg |
| `/var/lib/private/actual` | Actual dynamic-user state |
| `/var/lib/private/authentik` | Authentik dynamic-user state |
| `/var/lib/private/matrix-authentication-service` | MAS dynamic-user state and secrets |
| `/var/lib/systemd/timers` | Persistent system timer timestamps; `root:root 0755` |
| `/var/lib/systemd/timesync` | Saved clock state; `systemd-timesync:systemd-timesync 0755` |
| `/var/lib/wireguard` | WireGuard private key |
| `/home/mcp/.local/share/fish` | Fish history and other Fish data; directory persisted to permit atomic file replacement |

The OS random seed at `/var/lib/systemd/random-seed` is retained as a file. It is excluded from Borg and must not be restored from a historical archive or cloned to another host.

These paths live directly on the persistent dataset and need no additional bind mapping:

| Path | Purpose |
| --- | --- |
| `/persist/etc/machine-id` | Source for `/etc/machine-id` |
| `/persist/etc/ssh/ssh_host_ed25519_key` and `.pub` | Normal SSH host key, read directly by sshd |
| `/persist/credentials` | Manually provisioned host, boot, backup and reporting credentials |
| `/persist/var/lib/authentik/authentik-env` | Authentik environment file; separate from `/persist/var/lib/private/authentik` |
| `/persist/var/lib/apollo-backup` | Private backup ledger, deployment hold and upload-success evidence; excluded from Borg |
| `/persist/var/lib/apollo-alerts` | Private durable alert incidents/history; included in Borg |

## Ownership and file behavior

Static service data must retain its service owner and file-specific permissions. Impermanence's creation settings do not repair arbitrary existing trees. Do not apply one recursive owner or mode across all restored state.

Actual, Authentik and MAS use `DynamicUser` and `StateDirectory`. Their ordinary service paths resolve through the host's `/var/lib/private` tree. Both `/var/lib/private` and `/persist/var/lib/private` are restricted to `root:root 0700` by activation, without recursively changing their children. Dynamic account IDs and ID-mapped ownership can differ across boots or hosts; inspect service-namespace access rather than assigning old numeric UIDs. See [secret access](secrets.md#provisioning-and-access).

The random-seed service explicitly requires and follows Impermanence's generated file-persistence service. On a replacement, leave the backing seed absent so systemd can initialise a new one. Persist the Fish and logrotate directories rather than individual files because both replace state files atomically.

## Disposable state and backup boundaries

Unlisted root/home files, `/run`, temporary files, caches and generated runtime configurations are disposable unless contained in a listed persistent tree. Nginx cache and Redis state are not separately persisted here. A runtime secret file can reference additional paths; those references require their own persistence assessment.

Persistence retains data across root rollback. Backup coverage is narrower: the live database, Borg cache, random seed, backup ledger and selected logs are excluded. ZFS snapshots are local recovery points, not independent copies. Timer timestamp persistence preserves catch-up state only for timers that actually enable `Persistent=`; the coordinated capture and upload timers do not.
