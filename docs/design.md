# Design

[Repository overview](../README.md) · [Development](development.md) · [Services](services.md)

This document gives the reasons behind the configuration, and what is deliberately left out. The other documents describe what is configured. Change this document together with the decisions it describes.

## Goals

1. Secure enough for an internet-facing server that one person runs.
2. Declarative: the repository describes the whole server. Outside it remain application data, secrets and the provider accounts.
3. Reproducible on a new server from the repository and the backups.
4. Simple: every part has to justify its maintenance.
5. Public: readable as a showcase, without secrets or personal details.

## Repository

- One host, no framework. Option APIs (`options.apollo.*`), flake-parts and deployment tools such as colmena or deploy-rs pay off with several hosts or remote builds. Apollo builds its own system, and the flake has few outputs. Shared values belong in a plain imported file. [host.nix](../host.nix) holds Apollo’s addresses and the WireGuard network, and modules and tests import it.
- Two network definitions. The initrd configures its address with systemd-networkd. The running system uses NixOS’ scripted networking. Both read the same values, so what repeats is a few lines of structure. One networkd definition for both would replace the running system’s network stack on a server that is only reachable through it. The two also differ on purpose: the initrd has no IPv6.
- Service-owned modules. A service module declares everything of its service: package, sandbox, virtual host, database, persisted paths and secrets. Removing the module’s import removes the service.
- Explicit imports. `configuration.nix` lists every system and service module, system modules first. A module imports only what belongs to it: its sandbox file or the input module that it configures. Importing directories automatically would hide what is enabled.
- No hardening directory. Hardening belongs to what it protects: a sandbox to its service, SSH limits to SSH. Only the kernel settings stand alone.
- DNS records in the repository. [DNSControl](https://docs.dnscontrol.org/) applies the zones in [dns/](../dns/) from the operator’s machine, and shows every change before it happens. NixOS modules that generate zones pay off with many hosts. Here a flake check compares one list of web hosts with the virtual hosts. The credentials for INWX are encrypted to the admin key only, so CI and Apollo can’t change records. Whoever could change records would obtain certificates and receive mail for the domains.
- Application settings in Nix. Where an application can store its settings in a database, the configuration disables or replaces that:
  - Pleroma ignores its database configuration.
  - Authentik’s applications come from a blueprint.
  - A one-shot unit sets Nextcloud’s login.
  - Vaultwarden has no admin page.

## Updates and deployment

- Automatic updates of nixpkgs and the websites. Apollo updates these inputs every six hours and switches without review, so security fixes arrive within hours. nixpkgs’ release branches are built and tested before they advance, and the websites are packages built in the sandbox. The upgrade journal records every changed revision and package.
- Pinned module inputs. `authentik-nix`, `sops-nix`, `impermanence` and `disko` provide NixOS modules, which run as root, from branches that nobody reviews for Apollo. They only change with a reviewed commit to the lock file. The cost is that their fixes wait for the operator. A weekly check mails what the pinned revisions miss. A daily check mails when authentik-nix offers a newer Authentik.
- A third-party binary cache for Authentik. Building Authentik takes Apollo a long time, so Nix may fetch it from the nix-community cache. Nix asks cache.nixos.org first. The accepted risk is that the second cache can supply any path the first one lacks.
- Manual reboots. The operator enters the ZFS passphrase over SSH, so Apollo can’t reboot unattended. A new kernel or initrd only runs after the operator rebooted. A weekly check mails while one is waiting.
- Manual deploys. The operator deploys reviewed commits from `main` after CI passed. In the automatically updated inputs, Apollo’s lockfile is newer than Git’s. No push was checked with that combination.
- Scheduled checks that warn, not gate. Four times a day, CI updates the same inputs as Apollo in its own checkout, shortly before Apollo does, and runs every check. A failure mails the operator. Apollo upgrades regardless and may already run the revision that failed. Holding upgrades back until a check passed would delay security fixes and let an unreliable test block them.
- No tests on Apollo. Apollo is a virtual machine with its memory planned for the services, and it would build every test itself. A test that fails under load would block the upgrade.
- No CI that writes. A scheduled workflow that commits the lockfile it tested needs write access, and whoever controls it could then change Apollo. The scheduled checks only read.
- `stateVersion` stays `23.11`. It pins defaults that depend on when data was created, such as Vaultwarden’s data directory, not the release in use. Changing it would silently move data paths.
- Own nixpkgs for the websites. The website inputs build with their own locked nixpkgs, so Apollo’s updates can’t break them.
- Actual from unstable. Actual’s desktop app refuses servers older than itself, and stable releases lag behind Actual’s monthly releases. The unstable input can go if the web app replaces the desktop app.

## Secrets

- sops-nix with post-quantum age recipients only. Recipients derived from SSH host keys would be classical and cap the security of all secrets.
- The admin key exists only in KeePass, never as a file. Plaintext that already exists on Apollo is encrypted there with the host key and never leaves the server.
- Agents never see secret values. See [secrets](secrets.md).

## Hardening

Kernel settings, per-service systemd sandboxes and network restrictions each limit what a compromised service can do on its own.

- Sandboxes. Internet-facing services run with system call filters, minimal capabilities and a read-only system. `MemoryDenyWriteExecute` is only set where no JIT compiler runs. The Erlang VM needs one. Small helper units and units that need root by design stay unsandboxed.
- Network. Services can’t reach the WireGuard network unless their unit allows it. PostgreSQL and Redis have no network at all, and their clients use Unix sockets. Apollo forwards packets only from WireGuard peers to the internet.
- Backends behind Nginx. Every local process reaches a loopback port, past Nginx’s limits and with forwarding headers of its choice. Where Nginx is a backend’s only client, the backend listens on a Unix socket instead:
  - Pleroma’s socket only opens for its group, whose only other member is Nginx.
  - Nextcloud’s PHP-FPM and push daemon have the sockets of their NixOS modules.

  The others stay on loopback. Synapse and MAS call each other and only speak HTTP over TCP for that, so each keeps a loopback port. MAS’s port is the one that Nginx uses. Synapse’s port serves the client API, and Synapse has a socket for Nginx beside it, like Pleroma’s, and believes forwarding headers only there. MAS would gain nothing from a second listener, because Nginx limits none of its paths. Authentik’s server offers a Unix socket only in its temporary directory, next to its internal sockets and keys.
- Kernel. Targeted settings instead of a hardening profile, listed in [services](services.md#host-and-network).

Not used:

| Measure | Reason |
| --- | --- |
| NixOS hardened profile, locked kernel modules | Break ZFS, WireGuard, NAT and PHP |
| `linux-hardened` | Not in nixpkgs |
| Kernel lockdown, enforced module signatures | NixOS kernels are built without module signing, and ZFS is an external module |
| `init_on_free`, panic on oops | Cost with ZFS and PostgreSQL. Every panic would need a remote unlock. |
| Extra compiler hardening | Every package would lose the binary cache and build on Apollo |
| System-wide hardened allocator | The exposed runtimes use their own allocators. Risk of slowdowns and breakage. |
| fail2ban | Nginx rate-limits the login endpoints, and the applications throttle logins themselves |
| nix-mineral as an input | Desktop-oriented defaults, written for unstable, and another module input to review. The kernel settings here are set individually. |
| Vulnerability scanners on the closure | Name and version matching is noisy, and nixpkgs’ fixes reach Apollo within hours anyway. The pinned inputs have their own checks against their branches. |
| Hiding addresses and host names | No security gain |
| A `Content-Security-Policy` header from Nginx on every host | A policy belongs to whoever knows what the pages load. The applications send their own policy. A second policy from Nginx could only narrow it and would break with their upgrades. The website’s pages carry their policy in the page, with the hashes of their scripts. Framing is the one thing that a policy in the page can’t forbid, so `X-Frame-Options` denies it. Redirects and JSON have nothing to protect. Nginx sets a policy only where it knows the content: the hosts that serve no pages, the CVSS site and framing of Element Web. |

ZFS encryption protects disks at rest, not against a provider with access to the running machine.

## Access

- SSH only through WireGuard. SSH accepts one user, with keys declared in Nix and post-quantum key exchange. Only the initrd’s unlock SSH is public, because it runs before WireGuard exists. WireGuard peers use preshared keys against future quantum computers.
- Administration from the tunnel. Authentik superusers may only sign in from WireGuard addresses. Authentik’s API accepts tokens only from there. Pleroma’s admin paths only answer WireGuard addresses.
- Tunnel addresses in DNS only for navigation-only hosts. Browsers ask before a public page loads resources from a private address. Hosts whose pages embed resources, such as Pleroma’s, keep their public address.
- Client addresses. Authentik and Synapse take the first `X-Forwarded-For` entry, so Nginx replaces the header for them instead of appending to it. Actual and MAS take the last entry that no trusted proxy added, and trust only loopback addresses. Nextcloud trusts loopback addresses as well: its push daemon forwards its clients’ addresses and reaches Nextcloud through Nginx on loopback. The photo proxy’s upstream gets the appended header, which is correct for the same kind of backend.
- No local Nextcloud administrator. Authentik’s superusers are Nextcloud’s administrators, so the admin gate covers them too. `nextcloud-occ` on Apollo is the fallback.

## Data, backups and monitoring

- Upstream modules instead of custom code. Backups use the `borgbackup` module with one atomic ZFS snapshot. Alerts are a failure mail for every service, ZFS events, a disk space check and healthchecks.io for missing pings.
- Database dumps instead of the live cluster in backups. Restores need no PostgreSQL of the same version. The dumps only exist while the backup runs, so the local snapshots don’t keep a week of them.
- Off-site copies. The Storage Box keeps snapshots that Apollo can’t delete. Local snapshots are for mistakes, not a backup.
- No access logs. Nobody reads them, and they would hold the addresses of every visitor. The personal website counts page views without address or user agent, which is enough for trends.
- Logs stay in the journal. They reach the Storage Box every night with the backup. Central logging would add little for one host.
- PostgreSQL listens on its socket only, with a fixed memory budget next to the ZFS cache. Major upgrades go through dump and restore, which also reclaims space. Synapse needs a database with the collation `C`, which declarative provisioning can’t create. Its module therefore creates the database when a new cluster is initialised. `initialScript` takes a single file that only one module can set. If a second service has such a need, move the script to the PostgreSQL module.
- Pleroma, not Akkoma. Akkoma integrates better with NixOS, but moving there is large and one-way. Pleroma’s own task prunes old remote posts monthly.
