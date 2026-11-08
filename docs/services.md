# Services and host settings

[Repository overview](../README.md) · [Storage](storage.md) · [Operations](operations.md)

The declarations are in [service modules](../modules/), [host configuration](../configuration.nix) and the [local MAS module](../nixos-modules/matrix-authentication-service.nix). Package revisions come from [flake.lock](../flake.lock).

## Applications

| Service | Endpoint and backend | Dependencies and state |
| --- | --- | --- |
| Actual | `budget.ncrypt.at` → `127.0.0.1:5006` | Package from the unstable input; Authentik OIDC; SQLite and budget files in `/var/lib/actual` |
| Authentik | `idp.ncrypt.at` → HTTPS `localhost:9443` | PostgreSQL `authentik`; migration and worker services; media and SMTP; LDAP and RADIUS disabled |
| Matrix Synapse | `matrix.ncrypt.at` → `127.0.0.1:8008` | Server identity `ncrypt.at`; PostgreSQL `matrix-synapse`; media/signing keys; MAS; database compressor |
| Matrix Authentication Service | `auth.matrix.ncrypt.at` → `127.0.0.1:8091` | PostgreSQL `matrix-authentication-service`; internal health port `8092`; encryption/signing keys; SMTP; local passwords disabled |
| Element Web | `chat.ncrypt.at` | Nix-store frontend configured for the `ncrypt.at` homeserver |
| Nextcloud | `cloud.ncrypt.at`; package selection `nextcloud35` | PostgreSQL `nextcloud`; Redis, PHP-FPM, notify-push and cron; files and mutable configuration |
| Pleroma | `communicating.cypherpunk.observer` → `127.0.0.1:4000` | PostgreSQL `pleroma`; uploads/static files; runtime secrets and database-stored settings |
| Vaultwarden | `pw.ncrypt.at` → `127.0.0.1:8222` | PostgreSQL `vaultwarden`; attachments, sends, keys and SMTP; WebSocket forwarding enabled |
| Photo proxy | `photos.mkoppmann.at` → `10.100.0.2:2283` | Upstream reached through WireGuard; its database and media are outside Apollo's backup coverage |

Nextcloud's packaged apps are Calendar, Contacts, Notes, Tasks and User OIDC; automatic app updates are disabled. Its initial administrator is configured as `ncroot`, using the [administrator password file](secrets.md#credential-inventory). Login/provider registrations and secrets supplied through runtime files are not fully represented by this checkout. Synapse, Pleroma and Vaultwarden have public registration disabled. Pleroma ignores settings stored in its database; the admin interface can no longer change its configuration.

## HTTP routing and limits

[Nginx configuration](../modules/nginx.nix) terminates HTTPS using ACME certificates. Each service module declares its own virtual host; [websites](../modules/websites.nix) holds the static sites and redirects. Nginx enables the recommended proxy, TLS, gzip and optimisation settings and uses the stable Nginx package.

- Requests for unknown host names, including bare IP addresses, are closed without a response; TLS handshakes for them are rejected, so no certificate is revealed.
- Login form submissions are rate-limited per client address to 10 per minute with a burst of 20: Authentik's flow executor, Vaultwarden's token endpoint and Nextcloud's `/login`. Only POST requests count; exceeding the limit returns 429. The applications' own login throttling applies as well.

- Matrix discovery is served on `ncrypt.at`. Login/logout/refresh compatibility routes go to MAS; other Matrix and Synapse client/MAS routes go to Synapse. Other requests to the Matrix host return 404.
- Pleroma media redirects to `media.communicating.cypherpunk.observer`, which proxies and caches media. `/proxy` on the main Pleroma host returns 404.
- Authentik, Vaultwarden and the photo proxy enable WebSocket forwarding. Actual has its own cross-origin isolation headers and retains the application's CSP. Header policies vary by host and location.
- The configured limits differ: Nextcloud `16G`, Synapse `100M` with unlimited Nginx request bodies on its proxy locations, Pleroma's main virtual host `100m`, and the photo proxy `50000M` with 600-second proxy/send timeouts. Other limits come from application and module defaults.

| Static hostname | Content root |
| --- | --- |
| `www.mkoppmann.at` | `/srv/www/mkoppmann.at/dist` |
| `wtcvss.mkoppmann.at` | `/srv/www/wtcvss` |

These trees are persistent, mutable content deployed outside this flake. The MTA-STS policies for both domains are defined in the [websites module](../modules/websites.nix). The bare `cypherpunk.observer` and `mkoppmann.at` domains redirect to their `www` hosts. `ncrypt.at` redirects non-discovery requests to `www.ncrypt.at`. `www.ncrypt.at` and `www.cypherpunk.observer` answer every request with an empty HTTP 200.

## Host and network

| Setting | Declaration |
| --- | --- |
| Platform | `apollo`, `x86_64-linux`, QEMU/virtio guest, UEFI/systemd-boot |
| Network | Static `ens3`; DHCP and NetworkManager disabled |
| IPv4 | `152.53.35.165/22`, gateway `152.53.32.1` |
| IPv6 | `2a0a:4cc0:100:23::bad:c0de/64`, gateway `fe80::1` on `ens3` |
| DNS resolvers | Cloudflare `1.1.1.1`, `1.0.0.1`, `2606:4700:4700::1111`, `2606:4700:4700::1001` |
| Firewall openings | TCP `22`, `80`, `443`, `2222`; UDP `51820` |
| WireGuard | `wg0`, `10.100.0.1/24`; five peers at `10.100.0.2`–`10.100.0.6`, keepalive 25 seconds |
| NAT | NixOS-managed NAT from `wg0` through `ens3` |
| Administrator | `mcp`, wheel member, Fish shell, manually provisioned password hash |
| SSH | [SSH configuration](../modules/ssh.nix): only through WireGuard (firewall and `AllowUsers`); `mcp` only, with keys declared in Nix; public-key authentication; post-quantum hybrid key exchange only, also for remote unlock; Ed25519 host key; SFTP; all forwarding disabled; key fingerprints logged |
| Timezone | `Europe/Vienna` |
| Compatibility version | NixOS `stateVersion = "23.11"` |

The initrd uses the same static IPv4 route, IPv4 DNS resolvers and disabled IPv6 router advertisements. [Remote unlock](operations.md#remote-unlock) uses a separate SSH host key on port 2222. The normal root password is locked. [Kernel settings](../modules/kernel.nix) hide kernel pointers and logs from unprivileged users, restrict ptrace and BPF, ignore ICMP redirects and source routing, and disable kexec and hibernation. Zram swap, ZFS scrub/trim, weekly Nix garbage collection of generations older than 30 days and automatic store optimisation are enabled.

## Startup and certificate behavior

PostgreSQL 16 is configured for Unix-socket access and peer authentication; TCP listening is disabled. `postgresql.target` groups the server and separate role/database setup service. Apollo's explicit Authentik, Nextcloud setup and MAS dependencies name `postgresql.service`, rather than completion of that target. Recovery must verify both server and provisioning readiness.

Authentik migration precedes its worker/server. The worker loads the IdP certificate and key through systemd credentials when it starts; Apollo declares no certificate-renewal hook to refresh that worker's credentials. Actual, Authentik and MAS use dynamic users and systemd state directories; see [ownership](storage.md#ownership-and-file-behavior).
