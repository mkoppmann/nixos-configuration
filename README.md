# Apollo NixOS configuration

## Repository layout

| Path | Purpose |
| --- | --- |
| [flake.nix](flake.nix), [flake.lock](flake.lock) | System output and pinned inputs |
| [configuration.nix](configuration.nix) | Host, networking, persistence and Borg settings |
| [hardware-configuration.nix](hardware-configuration.nix) | Hardware and filesystem devices |
| [modules/](modules/) | Applications, reverse proxy, backups, alerts and automatic updates |
| [nixos-modules/](nixos-modules/) | Local Matrix Authentication Service module |
| [scripts/](scripts/) | Backup and alert programs; Nix supplies their runtimes |
| [tests/](tests/) | Python unit tests and Nix evaluation checks |
| [home.nix](home.nix) | Home Manager configuration for administrator `mcp` |

## Documentation

- [Services and host settings](docs/services.md)
- [Storage and persistent state](docs/storage.md)
- [Secrets and identities](docs/secrets.md)
- [Backup operation](docs/backups.md)
- [Email alerts](docs/alerts.md)
- [Validation, deployment and routine operations](docs/operations.md)
- [File and server recovery](docs/recovery.md)
- [PostgreSQL restoration](docs/postgresql-restore.md)
