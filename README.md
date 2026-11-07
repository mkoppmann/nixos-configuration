# Apollo NixOS configuration

## Repository layout

| Path | Purpose |
| --- | --- |
| [flake.nix](flake.nix), [flake.lock](flake.lock) | System output and pinned inputs |
| [configuration.nix](configuration.nix) | Module imports, time zone, Borg job and `stateVersion` |
| [hardware-configuration.nix](hardware-configuration.nix) | Hardware and filesystem devices |
| [modules/](modules/) | One module per service, owning its virtual host, database and persisted state; host modules for boot, networking, persistence, users and Nix; backups, alerts and automatic updates |
| [lib/](lib/) | Shared Nginx response-header snippets |
| [nixos-modules/](nixos-modules/) | Local Matrix Authentication Service module |
| [scripts/](scripts/) | Backup and alert programs; Nix supplies their runtimes |
| [tests/](tests/) | Python unit tests for the backup and alert scripts |
| [.github/workflows/](.github/workflows/) | CI: secret scan, tests and system build on every push |

## Documentation

- [Services and host settings](docs/services.md)
- [Storage and persistent state](docs/storage.md)
- [Secrets and identities](docs/secrets.md)
- [Backup operation](docs/backups.md)
- [Email alerts](docs/alerts.md)
- [Validation, deployment and routine operations](docs/operations.md)
- [File and server recovery](docs/recovery.md)
- [PostgreSQL restoration](docs/postgresql-restore.md)
