# Secrets and identities

[Repository overview](../README.md) · [Storage](storage.md) · [Recovery](recovery.md)

[sops-nix](https://github.com/Mic92/sops-nix) manages the service secrets. `secrets/apollo.yaml` is encrypted to two post-quantum age recipients listed in `.sops.yaml`: the admin key and Apollo’s host key. At activation, sops-nix decrypts the declared secrets to `/run/secrets` with the owner and mode each module declares. It renders files that mix secret and non-secret settings from templates. The operator provisions the initrd host key and the MAS files manually at the paths below. Never put secret values into Nix expressions: every user can read Nix-store files.

The INWX credentials for [DNS changes](operations.md#dns) are in `secrets/dnscontrol.yaml`, in the format of DNSControl’s `creds.json` under the key `inwx`. That file is encrypted to the admin key only, because Apollo never changes DNS records.

## Keys

| Key | Location |
| --- | --- |
| Admin (`age1pq1jqjfqh…`) | KeePass only, never as a file |
| Apollo host (`age1pq1sy6n0…`) | `/persist/var/lib/sops-nix/key.txt`, `root:root 0600`. Copy in KeePass. |

Both are post-quantum (`age-keygen -pq`). The SSH host keys are deliberately not used as age identities: they are classical keys.

## Editing secrets

Run this in a terminal without an agent session. While `sops edit` runs, the plaintext sits in a temporary file that your user can read.

```sh
nix develop
read -rsp "Admin key: " SOPS_AGE_KEY && export SOPS_AGE_KEY; echo   # paste from KeePass
sops edit secrets/apollo.yaml
unset SOPS_AGE_KEY
```

After you change `.sops.yaml` recipients, re-encrypt with `sops updatekeys secrets/apollo.yaml`. The `secrets-encrypted` flake check fails if any file in `secrets/` is not encrypted.

To import a value that already exists on Apollo, set it there with the host key, so the plaintext never leaves the server. Then copy the encrypted file back into the checkout:

```sh
sudo bash
cd /root && umask 077 && cp /etc/nixos/secrets/apollo.yaml .
nix shell nixpkgs#sops nixpkgs#jq -c bash -c 'printf %s "$(cat OLD_FILE)" | jq -Rs . | SOPS_AGE_KEY_FILE=/persist/var/lib/sops-nix/key.txt sops set --value-stdin apollo.yaml "[\"NAME\"]"'
install -o mcp -m 644 apollo.yaml /home/mcp/ && rm apollo.yaml
```

Then `scp mcp@apollo:apollo.yaml secrets/apollo.yaml` into the checkout and remove the copy on Apollo.

A new server can only decrypt the secrets after one of two steps. Either restore its host key from KeePass to `/persist/var/lib/sops-nix/key.txt`, or add a new host key as a recipient with `sops updatekeys`.

## Credential inventory

Paths below are configured readers or boot inputs. Files beneath persisted service trees have corresponding backing paths under `/persist`, listed in [storage](storage.md#retained-paths).

| Path | Format and consumer | Access requirement |
| --- | --- | --- |
| `/run/secrets-for-users/mcp_password_hash` | sops secret `mcp_password_hash`: yescrypt hash for `mcp`, decrypted before users are created | `root:root 0400`. Retain the actual sudo password independently. |
| `/persist/credentials/initrd_host_ed25519_key` | Dedicated unencrypted Ed25519 SSH host key for initrd | `root:root 0600`. Required when boot secrets are installed. |
| `/run/secrets/borg_passphrase` | sops secret `borg_passphrase` for the Borg repository | `root:root 0400`. A new value cannot unlock existing archives. Copy in KeePass. |
| `/run/secrets/borg_ssh_key` | sops secret `borg_ssh_key`: SSH client key authorised on the Storage Box, with trailing newline | `root:root 0400`. Copy in KeePass. |
| `/run/secrets/healthchecks_backup_url`, `/run/secrets/healthchecks_heartbeat_url` | sops secrets: healthchecks.io ping URLs. Anyone holding one can fake a ping. | `root:root 0400`. The heartbeat unit gets its URL with `LoadCredential`, and curl reads both from standard input. |
| `/run/secrets/reporting_smtp_password` | sops secret `reporting_smtp_password`: password for `reporting@ncrypt.at` | `root:root 0400`. msmtp reads it, so only root can send reports. |
| `/run/secrets/wireguard_private_key` | sops secret `wireguard_private_key` | `root:root 0400`. Changing it requires peer coordination. |
| `/run/secrets/wireguard_psk_peer2` … `wireguard_psk_peer6` | sops secrets with the preshared key of each WireGuard peer, named after the last octet of its address | `root:root 0400`. Each must match the peer’s client configuration. |
| `/run/secrets/actual_openid_client_secret` | sops secret `actual_openid_client_secret` for Actual’s Authentik OIDC client | `root:root 0400`. Passed to the dynamic user with `LoadCredential`. |
| `/run/secrets/rendered/authentik.env` | Template from `authentik_secret_key`, `authentik_smtp_password` and the OIDC client secrets `actual_openid_client_secret`, `immich_openid_client_secret`, `matrix_openid_client_secret` and `nextcloud_openid_client_secret`, which the applications blueprint reads. systemd environment file. | `root:root 0400`. Preserve the secret key with the database. Actual and Nextcloud read the same client secrets. Immich’s and MAS’s copies must match. |
| `/run/secrets/rendered/synapse-secrets.yaml` | Template from the `synapse_*` secrets, merged into Synapse’s configuration together with the email section | `matrix-synapse` reader, `0400` |
| `/var/lib/matrix-synapse/mas_secret` | Raw MAS/Synapse integration secret, same value as MAS’s `homeserver_secret` | `matrix-synapse` reader, `0600` |
| `/var/lib/private/matrix-authentication-service/secrets.yaml` | YAML with MAS encryption and signing keys, provider and client settings, and the SMTP password | Dynamic MAS reader, `0600` |
| `/var/lib/private/matrix-authentication-service/homeserver_secret` | Raw MAS/Synapse integration secret | Dynamic MAS reader, `0600`. Match Synapse’s runtime configuration. |
| `/run/secrets/rendered/nextcloud-secrets.json` | Template from the `nextcloud_*` secrets (instance ID, salt, secret, SMTP password) | `root:root 0400`. Passed with `LoadCredential`. |
| `/run/secrets/nextcloud_openid_client_secret` | sops secret `nextcloud_openid_client_secret` for Nextcloud’s Authentik login | `root:root 0400`. Passed to `nextcloud-oidc.service` with `LoadCredential`. |
| `/run/secrets/rendered/pleroma-secret.exs` | Template from `pleroma_secret_key_base` and `pleroma_vapid_private_key`. The VAPID public key is in Nix. | `pleroma` reader, `0400`. The VAPID key pair must match. |
| `/run/secrets/rendered/vaultwarden.env` | Template from `vaultwarden_smtp_password`. systemd environment file. | `root:root 0400` |

The values in sops have no quotes and no trailing newline, except `borg_ssh_key`, which ends with a newline. Templates insert the values verbatim. Environment-file syntax is not shell syntax, so do not source these files. Preserve the MAS files as a whole, because the repository doesn’t declare their contents.

## Identity and shared keys

The normal Ed25519 SSH host key and the machine ID come from `/persist/etc`, as listed in [storage](storage.md#retained-paths). Keep the private host key root-owned `0600` and the public key `0644`. The initrd host key is separate. After you change its source, reinstall the boot artifacts and verify the resulting fingerprint. The boot artifacts include the initrd host key, so it may reside on the unencrypted ESP.

Restore generated identities with their containing state:

- Synapse signing keys.
- MAS encryption and signing keys.
- Nextcloud instance configuration.
- Vaultwarden keys.
- Pleroma secrets and cookie.
- Authentik’s token signing key in its database.
- ACME account keys.

Restoring database contents alone does not recover an application’s identity or encrypted data.

MAS’s homeserver secret must match Synapse’s integration configuration. MAS local passwords are disabled, so authentication requires the upstream login configuration in MAS’s runtime YAML.

## Provisioning and access

Create `/persist/credentials` as `root:root 0700`. Stage new files privately outside the checkout with `umask 077`. Then install them with explicit owner, group and mode. Provision boot credentials before installation or rebuild. Provision service credentials before you start their consumers. Use a service’s actual runtime identity for static-reader files. Do not print values in command arguments, journals or shared terminal recordings.

On a new installation, these tools can generate the values:

- Password hashes: `mkpasswd --method=yescrypt`, interactively.
- SSH keys: `ssh-keygen`.
- WireGuard keys: `wg genkey`.
- Preshared keys: `wg genpsk`.

Generate unrelated secrets independently. On recovery, restore the existing values. Replacements do not preserve access to the existing repository or encrypted application state.

For dynamic-user services, restore complete backing trees while the service is stopped. Retain an unchanged extracted copy, and let systemd manage state-directory access. Check credentials from the service’s namespace with its sandbox settings in effect. Host ownership listings alone can be misleading. Do not hard-code a historical dynamic UID. Do not make the private parent directories traversable to other users.

Keep independently accessible copies of boot and repository credentials, verified SSH host fingerprints and application recovery material. Server backups include many of these files, but recovering the archive itself must not depend on a secret available only inside it.
