# Apollo NixOS configuration

## Repository layout

| Path | Purpose |
| --- | --- |
| [flake.nix](flake.nix), [flake.lock](flake.lock) | System output and pinned inputs |
| [configuration.nix](configuration.nix) | Module imports, time zone and `stateVersion` |
| [hardware-configuration.nix](hardware-configuration.nix) | Generated hardware settings |
| [modules/](modules/) | One module per service, owning its virtual host, database and persisted state; host modules for boot, disk layout, networking, persistence, users and Nix; backups, monitoring and automatic updates |
| [lib/](lib/) | Shared Nginx header snippets |
| [nixos-modules/](nixos-modules/) | Local Matrix Authentication Service module |
| [tests/](tests/) | NixOS VM tests: hardening, post-quantum secrets, backup and restore, installing on the disk layout, the Authentik and Nextcloud sandboxes |
| [.github/workflows/](.github/workflows/) | CI: secret scan, tests and system build on every push |

## Documentation

- [Services and host settings](docs/services.md)
- [Storage and persistent state](docs/storage.md)
- [Secrets and identities](docs/secrets.md)
- [Backup operation](docs/backups.md)
- [Monitoring](docs/monitoring.md)
- [Validation, deployment and routine operations](docs/operations.md)
- [File and server recovery](docs/recovery.md)
- [PostgreSQL restoration](docs/postgresql-restore.md)
