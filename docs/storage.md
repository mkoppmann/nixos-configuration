# Storage and persistent state

[Repository overview](../README.md) · [Secrets](secrets.md) · [Backups](backups.md) · [Recovery](recovery.md)

Storage is declared in [storage configuration](../modules/system/storage.nix), [boot configuration](../modules/system/boot.nix) and [persistence configuration](../modules/system/impermanence.nix); each [service module](../modules/services/) declares its own retained paths. The storage configuration describes the disk with [disko](https://github.com/nix-community/disko): a 512 MiB EFI system partition and the encrypted ZFS pool `rpool` on the rest. New installs create the layout from it, and the mounts below come from it. The pool’s passphrase is not in the repository; booting asks for it.

## Filesystems and boot

| Mount | Device | Role |
| --- | --- | --- |
| `/` | `rpool/local/root` | Disposable root; rolled back to `rpool/local/root@blank` in initrd |
| `/nix` | `rpool/local/nix` | Persistent Nix store |
| `/persist` | `rpool/safe/persist` | Persistent backing tree and credentials; needed for boot |
| `/var/log` | `rpool/safe/log` | Separate persistent logs; needed for boot |
| `/boot` | Partition named `ESP` | EFI system partition; `umask=0077` |

The ZFS mounts use `noatime`. Quotas keep the datasets that requests from outside can fill away from the applications’ data: 32 GiB for `/`, which holds Nginx’s cache and temporary files, and 16 GiB for `/var/log`. disko sets them on a new pool; on an existing one, `zfs set quota=…` does. The ZFS host ID is `e538f1c9`; forced root-pool import is disabled and encryption credentials are requested during boot. There is no disk swap declaration; zram swap is enabled.

`zfs-rollback.service` runs `zfs rollback -r "rpool/local/root@blank"` after pool import and before `sysroot.mount`. disko takes the snapshot right after creating the dataset. If the rollback fails, Apollo boots with the previous root, and `zfs-rollback-check.service` fails in the booted system, which sends a [failure mail](monitoring.md).

## Retained paths

Impermanence binds the following directory trees to corresponding paths under `/persist`. `hideMounts` marks them with `x-gvfs-hide` for graphical file managers; tools such as `findmnt` still show them. For example, `/var/lib/nextcloud` is backed by `/persist/var/lib/nextcloud`.

| Runtime paths | Contents |
| --- | --- |
| `/etc/nixos` | Deployment checkout, owned by `deploy` |
| `/root/.config/borg`, `/root/.cache/borg` | Borg configuration/security metadata and rebuildable cache; directories `0700` |
| `/var/backup` | PostgreSQL dumps and globals, only while a backup runs |
| `/var/lib/acme` | ACME accounts and certificates |
| `/var/lib/bitwarden_rs` | Vaultwarden attachments, sends and keys |
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
| `/home/mcp/.local/share/fish` | Fish history and other Fish data; directory persisted to permit atomic file replacement |

These paths live directly on the persistent dataset and need no additional bind mapping:

| Path | Purpose |
| --- | --- |
| `/persist/etc/machine-id` | Source for `/etc/machine-id` |
| `/persist/etc/ssh/ssh_host_ed25519_key` and `.pub` | Normal SSH host key, read directly by sshd |
| `/persist/credentials` | initrd SSH host key |
| `/persist/var/lib/sops-nix/key.txt` | sops host key |

## Ownership and file behavior

Static service data must retain its service owner and file-specific permissions. Impermanence’s creation settings do not repair arbitrary existing trees. Do not apply one recursive owner or mode across all restored state.

Actual, Authentik and MAS use `DynamicUser` and `StateDirectory`. Their ordinary service paths resolve through the host’s `/var/lib/private` tree. Both `/var/lib/private` and `/persist/var/lib/private` are restricted to `root:root 0700` by activation, without recursively changing their children. Dynamic account IDs and ID-mapped ownership can differ across boots or hosts; inspect service-namespace access rather than assigning old numeric UIDs. See [secret access](secrets.md#provisioning-and-access).

The Fish and logrotate directories are persisted rather than individual files, because both replace their state files atomically. The random seed in `/var/lib/systemd` is not persisted: the kernel gets its entropy from the CPU and the hypervisor.

## Disposable state and backup boundaries

Unlisted root/home files, `/run`, temporary files, caches and generated runtime configurations are disposable unless contained in a listed persistent tree. Nginx cache and Redis state are not separately persisted here. A runtime secret file can reference additional paths; those references require their own persistence assessment.

Persistence retains data across root rollback. Backup coverage is narrower: the live database (covered by dumps) and the Borg cache are excluded. ZFS snapshots are local recovery points, not independent copies. Timer timestamp persistence lets timers with `Persistent=`, such as the backup, catch up after downtime.
