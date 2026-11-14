# Apollo NixOS configuration

The complete, public configuration of Apollo, a personal NixOS server. Everything the server is, from its disk layout to each service’s sandbox, follows from the files in this repository.

## Why NixOS

Tools like Ansible describe steps that change a server’s existing state. Whatever the steps don’t cover stays behind: a manual fix, a package of a removed role, an outdated configuration file. Over time the server drifts away from its playbooks. NixOS instead builds the entire system from one configuration:

- **No drift.** Apollo’s root file system returns to an empty snapshot on every boot, and only explicitly persisted state survives. What isn’t declared here doesn’t exist on the server.
- **Safe updates.** Every change builds a complete new system next to the running one; a failed build changes nothing. Earlier systems stay bootable, so one command or the boot menu undoes a bad update.
- **Pinned inputs.** [flake.lock](flake.lock) pins every input, so a checkout evaluates to the same system on any machine. This goes beyond nixpkgs: the websites are flakes in their own repositories, pinned and built like any other package.
- **Tested in VMs.** The [tests](tests/) boot the real modules in throwaway virtual machines and check the security measures, backup and restore, and installation onto the declared disk layout. CI runs them and builds the system on every push.
- **Self-contained services.** Each [module](modules/) owns everything of its service: package, sandbox, virtual host, database, persisted directories and secrets. Removing its import removes the service; only its data stays.
- **Security as code.** The hardening is part of the configuration, not a checklist applied once:
  - Services run in systemd sandboxes with system call filters, minimal privileges and a read-only system. They can’t reach the WireGuard network unless allowed, and the databases have no network at all.
  - The kernel runs with hardened settings, and interfaces nothing here uses, such as io_uring, are switched off.
  - SSH and Authentik’s administrator logins only work through WireGuard. SSH accepts keys only, with post-quantum key exchange only.
  - Secrets are encrypted with sops for post-quantum age keys, so they live in this public repository next to the configuration that uses them.

Nix takes more learning than a playbook. In exchange, many mistakes show up as evaluation errors, build errors or failing VM tests before anything on the server changes.

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
| [.github/workflows/](.github/workflows/) | CI: secret scan, tests, link check and system build on every push |

## Documentation

- [Services and host settings](docs/services.md)
- [Storage and persistent state](docs/storage.md)
- [Secrets and identities](docs/secrets.md)
- [Backup operation](docs/backups.md)
- [Monitoring](docs/monitoring.md)
- [Validation, deployment and routine operations](docs/operations.md)
- [File and server recovery](docs/recovery.md)
- [PostgreSQL restoration](docs/postgresql-restore.md)
