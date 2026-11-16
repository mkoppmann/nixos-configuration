# Storage and persistent state

[Repository overview](../README.md) · [Secrets](secrets.md) · [Backups](backups.md) · [Recovery](recovery.md)

The [storage configuration](../modules/system/storage.nix), [boot configuration](../modules/system/boot.nix) and [persistence configuration](../modules/system/impermanence.nix) declare the storage. Each [service module](../modules/services/) declares its own retained paths. The storage configuration describes the disk with [disko](https://github.com/nix-community/disko): a 512 MiB EFI system partition and the encrypted ZFS pool `rpool` on the rest. New installs create the layout from it, and the mounts below come from it. The pool’s passphrase is not in the repository. The boot asks for it.

## Filesystems and boot

| Mount | Device | Role |
| --- | --- | --- |
| `/` | `rpool/local/root` | Disposable root. The initrd rolls it back to `rpool/local/root@blank`. |
| `/nix` | `rpool/local/nix` | Persistent Nix store |
| `/persist` | `rpool/safe/persist` | Persistent backing tree and credentials. Needed for boot. |
| `/var/log` | `rpool/safe/log` | Separate persistent logs. Needed for boot. |
| `/boot` | Partition named `ESP` | EFI system partition, `umask=0077` |

The ZFS mounts use `noatime`. Requests from outside can fill two datasets, and quotas keep those datasets away from the applications’ data. The quota is 32 GiB for `/`, which holds Nginx’s cache and temporary files, and 16 GiB for `/var/log`. disko sets the quotas on a new pool. On an existing pool, `zfs set quota=…` sets them. The ZFS host ID is `e538f1c9`. Forced root-pool import is disabled, and the boot requests the encryption credentials. There is no disk swap declaration. Zram swap is enabled.

`zfs-rollback.service` runs `zfs rollback -r "rpool/local/root@blank"` after pool import and before `sysroot.mount`. disko takes the snapshot right after it creates the dataset. If the rollback fails, Apollo boots with the previous root. `zfs-rollback-check.service` then fails in the booted system, which sends a [failure mail](monitoring.md).

## Retained paths

Impermanence binds the following directory trees to corresponding paths under `/persist`. `hideMounts` marks them with `x-gvfs-hide` for graphical file managers. Tools such as `findmnt` still show them. For example, `/persist/var/lib/nextcloud` backs `/var/lib/nextcloud`.

| Runtime paths | Contents |
| --- | --- |
| `/etc/nixos` | Deployment checkout, owned by `deploy` |
| `/root/.config/borg`, `/root/.cache/borg` | Borg configuration, security metadata and rebuildable cache. Directories `0700`. |
| `/var/backup` | PostgreSQL dumps and globals, only while a backup runs |
| `/var/lib/acme` | ACME accounts and certificates |
| `/var/lib/bitwarden_rs` | Vaultwarden attachments, sends and keys |
| `/var/lib/logrotate` | Rotation history at `status`. Directory `0700`. |
| `/var/lib/matrix-synapse` | Synapse media, keys and secrets |
| `/var/lib/nextcloud` | Nextcloud files, configuration and secrets |
| `/var/lib/nixos` | NixOS account mappings and other module state |
| `/var/lib/pleroma` | Pleroma uploads, static files and secrets |
| `/var/lib/postgresql` | Live PostgreSQL cluster, excluded from Borg |
| `/var/lib/private/actual` | Actual dynamic-user state |
| `/var/lib/private/authentik` | Authentik dynamic-user state |
| `/var/lib/private/matrix-authentication-service` | MAS dynamic-user state and secrets |
| `/var/lib/systemd/timers` | Persistent system timer timestamps, `root:root 0755` |
| `/var/lib/systemd/timesync` | Saved clock state, `systemd-timesync:systemd-timesync 0755` |
| `/home/mcp/.local/share/fish` | Fish history and other Fish data. The directory is persisted to permit atomic file replacement. |

These paths live directly on the persistent dataset and need no additional bind mapping:

| Path | Purpose |
| --- | --- |
| `/persist/etc/machine-id` | Source for `/etc/machine-id` |
| `/persist/etc/ssh/ssh_host_ed25519_key` and `.pub` | Normal SSH host key, which sshd reads directly |
| `/persist/credentials` | initrd SSH host key |
| `/persist/var/lib/sops-nix/key.txt` | sops host key |

## Ownership and file behavior

Static service data must retain its service owner and file-specific permissions. Impermanence’s creation settings do not repair arbitrary existing trees. Do not apply one recursive owner or mode across all restored state.

Actual, Authentik and MAS use `DynamicUser` and `StateDirectory`. Their ordinary service paths resolve through the host’s `/var/lib/private` tree. Activation restricts both `/var/lib/private` and `/persist/var/lib/private` to `root:root 0700`, without recursively changing their children. Dynamic account IDs and ID-mapped ownership can differ across boots or hosts. Inspect service-namespace access instead of assigning old numeric UIDs, as [secret access](secrets.md#provisioning-and-access) describes.

Impermanence persists the Fish and logrotate directories instead of individual files, because both programs replace their state files atomically. The random seed in `/var/lib/systemd` is not persisted: the kernel gets its entropy from the CPU and the hypervisor.

## Disposable state and backup boundaries

Unlisted root and home files, `/run`, temporary files, caches and generated runtime configurations are disposable unless a listed persistent tree contains them. Nginx cache and Redis state are not separately persisted here. A runtime secret file can reference additional paths. Assess the persistence of those paths separately.

Persistence retains data across root rollback. Backup coverage is narrower: it excludes the live database, which the dumps cover, and the Borg cache. ZFS snapshots are local recovery points, not independent copies. The persisted timer timestamps let timers with `Persistent=`, such as the backup, run a missed start after downtime.
