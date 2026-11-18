# Services and host settings

[Repository overview](../README.md) · [Storage](storage.md) · [Operations](operations.md)

The declarations are in [service modules](../modules/services/), [system modules](../modules/system/) and the [local MAS module](../nixos-modules/matrix-authentication-service.nix). [configuration.nix](../configuration.nix) imports them. Package revisions come from [flake.lock](../flake.lock).

## Applications

| Service | Endpoint and backend | Dependencies and state |
| --- | --- | --- |
| Actual | `budget.ncrypt.at` → `127.0.0.1:5006` | Package from the unstable input. Authentik OIDC. SQLite and budget files in `/var/lib/actual`. |
| Authentik | `idp.ncrypt.at` → HTTPS `localhost:9443` | PostgreSQL `authentik`. Migration and worker services. Media and SMTP. LDAP and RADIUS disabled. Listens on loopback only. |
| Matrix Synapse | `matrix.ncrypt.at` → `/run/matrix-synapse/nginx.sock` | Server identity `ncrypt.at`. PostgreSQL `matrix-synapse`. Media and signing keys. MAS, which uses the client API on `127.0.0.1:8008`. Database compressor. |
| Matrix Authentication Service | `auth.matrix.ncrypt.at` → `127.0.0.1:8091`, which Synapse uses as well | PostgreSQL `matrix-authentication-service`. Internal health port `8092`. Encryption and signing keys. SMTP. Local passwords disabled. |
| Element Web | `chat.ncrypt.at` | Nix-store frontend configured for the `ncrypt.at` homeserver |
| Nextcloud | `cloud.ncrypt.at`, package selection `nextcloud35` | PostgreSQL `nextcloud`. Redis, PHP-FPM, notify-push and cron, all on Unix sockets. Files and mutable configuration. `cloud.ncrypt.at` resolves to loopback on Apollo, so the push daemon reaches Nextcloud through Nginx there. |
| Pleroma | `communicating.cypherpunk.observer` → `/run/pleroma/http.sock` | PostgreSQL `pleroma`. Uploads, static files and runtime secrets. The Erlang distribution that `pleroma_ctl` uses listens on loopback only, with the cookie from `/var/lib/pleroma/.cookie`. The metrics server is off. |
| Vaultwarden | `pw.ncrypt.at` → `127.0.0.1:8222` | PostgreSQL `vaultwarden`. Attachments, sends, keys and SMTP. WebSocket forwarding enabled. |
| Photo proxy | `photos.mkoppmann.at` → `10.100.0.2:2283` | Upstream reached through WireGuard. Its database and media are outside Apollo’s backup coverage. |

Nextcloud’s packaged apps are Calendar, Contacts, Notes, Tasks, User OIDC and Client Push (`notify_push`). Automatic app updates are disabled. ImageMagick is off: previews come from PHP’s GD, which leaves out formats such as HEIC, TIFF and SVG. Nextcloud has no local administrator: Authentik’s superusers are Nextcloud’s administrators. Every login sets the membership of Nextcloud’s `admin` group from Authentik’s claim and leaves other groups alone. `nextcloud-occ` on Apollo works even when Authentik is down. `nextcloud-oidc.service` sets Nextcloud’s Authentik login.

The [applications blueprint](../modules/services/authentik/applications.yaml) defines Authentik’s OAuth2 providers and applications for Actual, Immich, Matrix and Nextcloud, and their access groups. Group membership stays in Authentik’s database. Authentik’s admin gate denies superusers that sign in or recover their password from outside the WireGuard network. Their sessions end as soon as their IP address changes. `sudo ak create_recovery_key 1 USERNAME` on Apollo creates a one-time login link for emergencies. API tokens and app passwords don’t pass the login flow. Nginx therefore refuses requests to Authentik’s API that carry an `Authorization` header from outside the WireGuard network. `authentik-update-check.service` fails once a day while authentik-nix offers another Authentik release than the pinned one, as [operations](operations.md#automatic-updates) describes.

Synapse, Pleroma and Vaultwarden have public registration disabled. Vaultwarden has no admin page, and organisation admins invite new users by email. Pleroma ignores settings stored in its database, so its admin interface can’t change the configuration.

## HTTP routing and limits

[Nginx configuration](../modules/services/nginx.nix) terminates HTTPS with ACME certificates. Each service module declares its own virtual host. [Websites](../modules/services/websites.nix) holds the static sites and redirects. Nginx enables the recommended proxy, TLS, gzip and optimisation settings and uses the stable Nginx package. It serves every virtual host over HTTP/1.1 only.

- Nginx closes requests for unknown host names, including bare IP addresses, without a response. It rejects TLS handshakes for them, so it reveals no certificate.
- Nginx keeps no access log. Only `www.mkoppmann.at` logs its page views to `/var/log/nginx/visits.log`, with nothing that identifies a visitor. A log line holds the hour, the status, whether the client calls itself a program, the referring site and the path. `sudo visits` prints the views per day and the most viewed pages and referring sites. The personal sites (`mkoppmann.at`, `www.mkoppmann.at`, `wtcvss.mkoppmann.at`) also keep failed requests, which name the client’s address, out of Nginx’s error log.
- Every host serves `/.well-known/security.txt` with the contact `security@ncrypt.at`. The [Nginx module](../modules/services/nginx.nix) adds it to every virtual host, whichever module declares the host. The module sets the expiry date a year after the date of the nixpkgs revision, so automatic updates keep it current.
- Every host sends HSTS. On proxied hosts Nginx adds the header to all responses, including its own redirects and errors, and drops the backend’s copy. The [whole-system test](../tests/apollo.nix) counts the header on every host.
- Nginx sends a `Content-Security-Policy` where it knows the content. The hosts that serve no pages get a policy without scripts. `wtcvss.mkoppmann.at` gets its own policy, and Element Web gets its framing rule. `www.mkoppmann.at` carries its policy in its pages, and the proxied applications send their own. [Design](design.md#hardening) gives the reasons.
- Nginx rate-limits login form submissions per client, by IPv4 address or IPv6 /64, to 10 per minute with a burst of 20. The limit covers Authentik’s flow executor, Vaultwarden’s token endpoint and Nextcloud’s `/login`. Only POST requests count. A request over the limit returns 429. The applications’ own login throttling applies as well.
- `ncrypt.at` serves Matrix discovery. The compatibility routes for login, logout and refresh go to MAS. Other `/_matrix` and `/_synapse/client` routes go to Synapse. `/_synapse/mas` is not exposed. Other requests to the Matrix host return 404.
- Pleroma media redirects to `media.communicating.cypherpunk.observer`, which proxies and caches media. `/proxy` on the main Pleroma host returns 404. On the 2nd of every month, `pleroma-prune.service` deletes remote posts older than a year. It keeps threads with local activity, bookmarked ones and non-public ones. It then deletes the activities left without their post. A [patch](../modules/services/pleroma/prune-in-batches.patch) makes Pleroma delete them in batches, so incoming posts don’t wait for the deletion. Automatic upgrades pause while it runs, and a failed query fails the unit. Pleroma’s admin API, admin frontend and dashboards (`/api/v1/pleroma/admin`, `/pleroma/admin`, `/pleroma/live_dashboard`, `/pleroma/oban`) answer only WireGuard addresses. They need a client that routes all traffic through the tunnel.
- Every file in the Nix store has the same date, from 1970. nixpkgs’ Nginx therefore sends store files without a date and with an ETag made of their store path. The sites served from the store (`www.mkoppmann.at`, `wtcvss.mkoppmann.at` and Element Web) also send `Cache-Control: no-cache`. Browsers then ask every time by instruction and not by their own choice. They get a 304 while the file’s store path is unchanged. Caches may keep the website’s content-hashed `/_astro/` files for a year. Authentik’s own server does send the date, and an ETag made of the date and the file’s length. A rebuilt file of the same length would therefore pass for unchanged. Nginx therefore serves Authentik’s `/static/` from the store itself, with `Cache-Control: no-cache`. Caches may keep only the frontend’s chunks, whose names are content hashes, for a year. The frontend’s assets also hold files with fixed names. The copies that Authentik serves below `/if/` still pass through the proxy with the date.
- Authentik, Vaultwarden and the photo proxy enable WebSocket forwarding. Actual has its own cross-origin isolation headers and retains the application’s CSP. Header policies vary by host and location.
- The configured limits differ: Nextcloud `16G`, Synapse `100M` in Synapse and in Nginx, Pleroma’s main virtual host `100m`, and the photo proxy `50000M` with 600-second proxy and send timeouts. The photo proxy passes uploads on while they arrive instead of storing them on Apollo first. Other limits come from application and module defaults.

| Static hostname | Source |
| --- | --- |
| `www.mkoppmann.at` | Flake input `website` ([mkoppmann/website](https://github.com/mkoppmann/website)) |
| `wtcvss.mkoppmann.at` | Flake input `wtcvss` ([mkoppmann/wtcvss](https://github.com/mkoppmann/wtcvss)) |

Nix builds both sites from their repositories with their own locked nixpkgs, and Nginx serves them from the Nix store. Each automatic upgrade takes their latest commits. A site that fails to build fails the whole upgrade. The [websites module](../modules/services/websites.nix) defines the MTA-STS policies for both domains. The bare `cypherpunk.observer` and `mkoppmann.at` domains redirect to their `www` hosts. `ncrypt.at` redirects non-discovery requests to `www.ncrypt.at`. `www.ncrypt.at` and `www.cypherpunk.observer` answer every request with an empty HTTP 200.

## Host and network

| Setting | Declaration |
| --- | --- |
| Platform | `apollo`, `x86_64-linux`, QEMU/virtio guest, UEFI/systemd-boot |
| Network | Static `ens3`. DHCP and NetworkManager disabled. |
| IPv4 | `152.53.35.165/22`, gateway `152.53.32.1` |
| IPv6 | `2a0a:4cc0:100:23::bad:c0de/64`, gateway `fe80::1` on `ens3` |
| DNS resolver | [Unbound](../modules/system/dns.nix) on `127.0.0.1`, `::1` and `10.100.0.1`. It forwards over TLS to `dot1.applied-privacy.net` and resolves directly from the authoritative servers if that fails. For WireGuard clients it answers `idp.ncrypt.at` with `10.100.0.1` and without IPv6 address, so Authentik sees WireGuard clients by their tunnel address. |
| Firewall | nftables. Public: TCP `80`, `443`, UDP `51820`. On `wg0` only: TCP `22`, TCP and UDP `53`. Forwarded: only from `wg0` to `ens3` and the replies. The initrd has no firewall, and its unlock SSH listens on TCP `2222`. |
| WireGuard | `wg0`, `10.100.0.1/24`. Peers `peer2`–`peer6` at `10.100.0.2`–`10.100.0.6`, each with a preshared key. Peers reach Apollo and the internet, but not each other, and the internet doesn’t reach them through Apollo. |
| NAT | NixOS-managed NAT from `wg0` through `ens3` |
| Administrator | `mcp`, wheel member, Fish shell, password hash from sops |
| SSH | [SSH configuration](../modules/system/ssh.nix): only through WireGuard (firewall and `AllowUsers`). `mcp` only, with keys declared in Nix. Public-key authentication. Post-quantum hybrid key exchange only, also for remote unlock, where the keys only answer the passphrase prompt. Ed25519 host key. SFTP. All forwarding disabled. Key fingerprints logged. |
| Timezone | `Europe/Vienna` |
| Compatibility version | NixOS `stateVersion = "23.11"` |

The initrd has the same IPv4 address and route, but no IPv6 and no DNS resolver. [Remote unlock](operations.md#remote-unlock) uses a separate SSH host key on port 2222. The normal root password is locked. The [kernel settings](../modules/system/kernel.nix):

- Hide kernel pointers and logs from unprivileged users.
- Restrict ptrace, BPF and writes through `/proc/PID/mem`.
- Ignore ICMP redirects and source routing.
- Keep slab caches apart.
- Store no memory dumps of crashed processes.
- Disable kexec, hibernation, io_uring, 32-bit system calls and debugfs.
- Disable the automatic loading of unused network protocols, the kernel’s crypto sockets (AF_ALG) and line disciplines.

Zram swap, ZFS scrub and trim, weekly Nix garbage collection of generations older than 30 days and automatic store optimisation are enabled. The boot menu lists the ten newest generations.

## Startup and certificate behavior

PostgreSQL 16 accepts Unix-socket access with peer authentication, and TCP listening is disabled. The memory budget assumes 15 GiB of RAM. The ZFS cache is capped at 4 GiB, PostgreSQL gets 2 GiB of shared buffers, and the applications get the rest. Autovacuum starts at 5 % dead rows, and PostgreSQL loads `pg_stat_statements` for query statistics. `postgresql.target` groups the server and the separate role and database setup service. The services that use a database start after it.

Authentik’s database migrations run as a separate one-shot unit. The server and worker start only after it succeeds. Authentik’s OAuth2 providers sign tokens with Authentik’s self-signed key, which its database stores and which is independent of the TLS certificate. Actual, Authentik and MAS use dynamic users and systemd state directories, as [ownership](storage.md#ownership-and-file-behavior) describes.
