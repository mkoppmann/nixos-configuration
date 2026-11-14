# Design

[Repository overview](../README.md) · [Development](development.md) · [Services](services.md)

Goals, decisions and rejected alternatives that the configuration itself doesn’t show. The other documents describe what is configured; this one records why, and what was deliberately left out. Change it together with the decisions it describes.

## Goals

1. Secure enough for an internet-facing server that one person runs.
2. Declarative: the repository describes the whole server. Outside it remain application data, secrets, DNS records and the provider account.
3. Reproducible on a new server from the repository and the backups.
4. Simple: every part has to justify its maintenance.
5. Public: readable as a showcase, without secrets or personal details.

## Repository

- **One host, no framework.** Option APIs (`options.apollo.*`), flake-parts and deployment tools such as colmena or deploy-rs pay off with several hosts or remote builds. Apollo builds its own system, and the flake has few outputs. Shared values such as addresses belong in a plain imported file.
- **Service-owned modules.** A service module declares everything of its service: package, sandbox, virtual host, database, persisted paths and secrets. Removing its import removes the service.
- **Explicit imports.** `configuration.nix` lists every module, system modules first. Importing directories automatically would hide what is enabled.
- **No hardening directory.** Hardening belongs to what it protects: a sandbox to its service, SSH limits to SSH. Only the kernel settings stand alone.
- **Application settings in Nix.** Where an application can store its settings in a database, that is disabled or replaced: Pleroma ignores its database configuration, Authentik’s applications come from a blueprint, Nextcloud’s login is set by a one-shot unit, and Vaultwarden has no admin page.

## Updates and deployment

- **Automatic updates of nixpkgs and the websites.** Apollo updates these inputs every six hours and switches without review, so security fixes arrive within hours. nixpkgs’ release branches are built and tested before they advance, and the websites are packages built in the sandbox. The upgrade journal records every changed revision and package.
- **Pinned module inputs.** `authentik-nix`, `sops-nix`, `impermanence` and `disko` provide NixOS modules, which run as root, from branches that nobody reviews for Apollo. They only change with a reviewed commit to the lock file. The cost is that an Authentik fix waits for the operator; a daily check mails when authentik-nix offers a newer release.
- **A third-party binary cache for Authentik.** Building Authentik takes Apollo a long time, so Nix may fetch it from the nix-community cache. Nix asks cache.nixos.org first; the accepted risk is that the second cache can supply any path the first one lacks.
- **Manual deploys.** The operator deploys reviewed commits from `main` after CI passed. Apollo’s lockfile is newer than Git’s in the automatically updated inputs, a combination CI hasn’t tested.
- **No CI that writes.** A scheduled workflow that updates and tests the lockfile needs write access, and whoever controls it could then change Apollo.
- **`stateVersion` stays `23.11`.** It pins defaults that depend on when data was created, such as Vaultwarden’s data directory, not the release in use. Changing it would silently move data paths.
- **Own nixpkgs for the websites.** The website inputs build with their own locked nixpkgs, so Apollo’s updates can’t break them.
- **Actual from unstable.** Actual’s desktop app refuses servers older than itself, and stable releases lag behind Actual’s monthly releases. The unstable input can go if the web app replaces the desktop app.

## Secrets

- sops-nix with post-quantum age recipients only. Recipients derived from SSH host keys would be classical and cap the security of all secrets.
- The admin key exists only in KeePass, never as a file. Plaintext that already exists on Apollo is encrypted there with the host key and never leaves the server.
- Agents never see secret values. See [secrets](secrets.md).

## Hardening

Kernel settings, per-service systemd sandboxes and network restrictions each limit what a compromised service can do on its own.

- **Sandboxes.** Internet-facing services run with system call filters, minimal capabilities and a read-only system. `MemoryDenyWriteExecute` is only set where no JIT compiler runs; the Erlang VM needs one. Small helper units and units that need root by design stay unsandboxed.
- **Network.** Services can’t reach the WireGuard network unless their unit allows it. PostgreSQL and Redis have no network at all; their clients use Unix sockets. Backends listen on loopback, behind Nginx. Apollo forwards packets only from WireGuard peers to the internet.
- **Kernel.** Targeted settings instead of a hardening profile; see [services](services.md#host-and-network).

Considered and rejected:

| Measure | Reason |
| --- | --- |
| NixOS hardened profile, locked kernel modules | Break ZFS, WireGuard, NAT and PHP |
| `linux-hardened` | Removed from nixpkgs for lack of maintenance |
| Kernel lockdown, enforced module signatures | NixOS kernels are built without module signing; ZFS is an external module |
| `init_on_free`, panic on oops | Cost with ZFS and PostgreSQL; every panic would need a remote unlock |
| Extra compiler hardening | Every package would lose the binary cache and build on Apollo |
| System-wide hardened allocator | The exposed runtimes use their own allocators; risk of slowdowns and breakage |
| fail2ban | Login endpoints are rate-limited by Nginx, and the applications throttle logins themselves |
| nix-mineral as an input | Desktop-oriented defaults, written for unstable; another module input to review. The kernel settings here are set individually |
| Vulnerability scanners on the closure | Name and version matching is noisy, and nixpkgs’ fixes reach Apollo within hours anyway. The one pinned application, Authentik, has its own release check |
| Hiding addresses and host names | No security gain |

ZFS encryption protects disks at rest, not against a provider with access to the running machine.

## Access

- **SSH only through WireGuard,** for one user with keys declared in Nix and post-quantum key exchange. Only the initrd’s unlock SSH is public, because it runs before WireGuard exists. WireGuard peers use preshared keys against future quantum computers.
- **Administration from the tunnel.** Authentik superusers may only sign in from WireGuard addresses, Authentik’s API accepts tokens only from there, and Pleroma’s admin paths only answer WireGuard addresses.
- **Tunnel addresses in DNS only for navigation-only hosts.** Browsers ask before a public page loads resources from a private address. Hosts whose pages embed resources, such as Pleroma’s, keep their public address.
- **Client addresses.** Authentik and Synapse take the first `X-Forwarded-For` entry, so Nginx replaces the header for them instead of appending to it.
- **No local Nextcloud administrator.** Authentik’s superusers are Nextcloud’s administrators, so the admin gate covers them too; `nextcloud-occ` on Apollo is the fallback.

## Data, backups and monitoring

- **Upstream modules instead of custom code.** Backups use the `borgbackup` module with one atomic ZFS snapshot; alerts are a failure mail for every unit, ZFS events, a disk space check and healthchecks.io for missing pings.
- **Database dumps instead of the live cluster** in backups; restores need no PostgreSQL of the same version.
- **Off-site copies.** The Storage Box keeps snapshots that Apollo can’t delete. Local snapshots are for mistakes, not a backup.
- **Logs stay in the journal.** They reach the Storage Box every night with the backup; central logging would add little for one host.
- **PostgreSQL** listens on its socket only, with a fixed memory budget next to the ZFS cache. Major upgrades go through dump and restore, which also reclaims space.
- **Pleroma stays.** Akkoma integrates better with NixOS, but moving there is large and one-way. Old remote posts are pruned monthly with Pleroma’s own task.
