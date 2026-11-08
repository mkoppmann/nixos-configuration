# Secrets and identities

[Repository overview](../README.md) · [Storage](storage.md) · [Recovery](recovery.md)

Service secrets are managed with [sops-nix](https://github.com/Mic92/sops-nix): `secrets/apollo.yaml` is encrypted to two post-quantum age recipients listed in `.sops.yaml`, the admin key and Apollo's host key. At activation, sops-nix decrypts the declared secrets to `/run/secrets` with the owner and mode each module declares; files that mix secret and non-secret settings are rendered from templates. The initrd host key and the MAS files are still provisioned manually at the paths below. Never put secret values into Nix expressions: Nix-store files are readable by every user.

## Keys

| Key | Location |
| --- | --- |
| Admin (`age1pq1jqjfqh…`) | KeePass only, never as a file |
| Apollo host (`age1pq1sy6n0…`) | `/persist/var/lib/sops-nix/key.txt`, `root:root 0600`; copy in KeePass |

Both are post-quantum (`age-keygen -pq`). The SSH host keys are deliberately not used as age identities: they are classical keys.

## Editing secrets

Run this in a terminal without an agent session; while `sops edit` runs, the plaintext sits in a temporary file readable by your user.

```sh
nix develop
read -rsp "Admin key: " SOPS_AGE_KEY && export SOPS_AGE_KEY; echo   # paste from KeePass
sops edit secrets/apollo.yaml
unset SOPS_AGE_KEY
```

After changing `.sops.yaml` recipients, re-encrypt with `sops updatekeys secrets/apollo.yaml`. The `secrets-encrypted` flake check fails if any file in `secrets/` is not encrypted.

To import a value that already exists on Apollo, set it there with the host key so the plaintext never leaves the server, then copy the encrypted file back into the checkout:

```sh
sudo bash
cd /root && umask 077 && cp /etc/nixos/secrets/apollo.yaml .
nix shell nixpkgs#sops nixpkgs#jq -c bash -c 'printf %s "$(cat OLD_FILE)" | jq -Rs . | SOPS_AGE_KEY_FILE=/persist/var/lib/sops-nix/key.txt sops set --value-stdin apollo.yaml "[\"NAME\"]"'
install -o mcp -m 644 apollo.yaml /home/mcp/ && rm apollo.yaml
```

Then `scp mcp@apollo:apollo.yaml secrets/apollo.yaml` into the checkout and remove the copy on Apollo.

A new server can only decrypt the secrets once its host key is restored from KeePass to `/persist/var/lib/sops-nix/key.txt`, or after a new host key is added as a recipient with `sops updatekeys`.

## Credential inventory

Paths below are configured readers or boot inputs. Files beneath persisted service trees have corresponding backing paths under `/persist`; see [storage](storage.md#retained-paths).

| Path | Format and consumer | Access requirement |
| --- | --- | --- |
| `/run/secrets-for-users/mcp_password_hash` | sops secret `mcp_password_hash`: yescrypt hash for `mcp`, decrypted before users are created | `root:root 0400`; retain the actual sudo password independently |
| `/persist/credentials/initrd_host_ed25519_key` | Dedicated unencrypted Ed25519 SSH host key for initrd | `root:root 0600`; required when boot secrets are installed |
| `/run/secrets/borg_passphrase` | sops secret `borg_passphrase` for the Borg repository | `root:root 0400`; a new value cannot unlock existing archives; copy in KeePass |
| `/run/secrets/borg_ssh_key` | sops secret `borg_ssh_key`: SSH client key authorised on the Storage Box, with trailing newline | `root:root 0400`; copy in KeePass |
| `/run/secrets/healthchecks_backup_url`, `/run/secrets/healthchecks_heartbeat_url` | sops secrets: healthchecks.io ping URLs; anyone holding one can fake a ping | `root:root 0400` |
| `/run/secrets/reporting_smtp_password` | sops secret `reporting_smtp_password`: password for `reporting@ncrypt.at` | `root:root 0400`; loaded into the SMTP worker using systemd credentials |
| `/run/secrets/wireguard_private_key` | sops secret `wireguard_private_key` | `root:root 0400`; changing it requires peer coordination |
| `/run/secrets/actual_openid_client_secret` | sops secret `actual_openid_client_secret` for Actual's Authentik OIDC client | `root:root 0400`; passed to the dynamic user with `LoadCredential` |
| `/run/secrets/rendered/authentik.env` | Template from `authentik_secret_key`, `authentik_smtp_password` and the OIDC client secrets `actual_openid_client_secret`, `immich_openid_client_secret`, `matrix_openid_client_secret` and `nextcloud_openid_client_secret`, which the applications blueprint reads; systemd environment file | `root:root 0400`; preserve the secret key with the database; each client secret must match the application’s copy |
| `/run/secrets/rendered/synapse-secrets.yaml` | Template from the `synapse_*` secrets, merged into Synapse's configuration together with the email section | `matrix-synapse` reader, `0400` |
| `/var/lib/matrix-synapse/mas_secret` | Raw MAS/Synapse integration secret, same value as MAS's `homeserver_secret` | `matrix-synapse` reader, `0600` |
| `/var/lib/private/matrix-authentication-service/secrets.yaml` | YAML containing MAS encryption/signing keys, provider/client settings and SMTP password | Dynamic MAS reader, `0600` |
| `/var/lib/private/matrix-authentication-service/homeserver_secret` | Raw MAS/Synapse integration secret | Dynamic MAS reader, `0600`; match Synapse's runtime configuration |
| `/run/secrets/rendered/nextcloud-secrets.json` | Template from the `nextcloud_*` secrets (instance ID, salt, secret, SMTP password) | `root:root 0400`; passed with `LoadCredential` |
| `/run/secrets/nextcloud_openid_client_secret` | sops secret `nextcloud_openid_client_secret` for Nextcloud’s Authentik login | `root:root 0400`; passed to `nextcloud-oidc.service` with `LoadCredential` |
| `/run/secrets/nextcloud_admin_password` | sops secret `nextcloud_admin_password` for initial creation of administrator `ncroot` | `root:root 0400`; must remain nonempty for the setup service |
| `/run/secrets/rendered/pleroma-secret.exs` | Template from `pleroma_secret_key_base` and `pleroma_vapid_private_key`; the VAPID public key is in Nix | `pleroma` reader, `0400`; the VAPID key pair must match |
| `/run/secrets/rendered/vaultwarden.env` | Template from `vaultwarden_smtp_password`; systemd environment file | `root:root 0400` |
| `/var/lib/acme/idp.ncrypt.at/fullchain.pem` and `key.pem` | ACME-managed certificate/key loaded by the Authentik worker | Preserve module-managed ownership and restrictive permissions |

sops values are stored without quotes or trailing newline; templates insert them verbatim. Environment-file syntax is not shell syntax; do not source these files. The remaining MAS files still have to be preserved as a whole: the checkout cannot establish their complete contents.

Nextcloud's `config.adminuser` and `config.adminpassFile` set administrator credentials only during initial installation. Changing them does not rename an existing account or reset its password. The [locked Nextcloud module](https://github.com/NixOS/nixpkgs/blob/f546a0b3db840c7c8a7c705265fc6b42bcbfe278/nixos/modules/services/web-apps/nextcloud.nix) still loads and checks the password file on each setup-service invocation, including for an existing installation.

## Identity and shared keys

The normal Ed25519 SSH host key and the machine ID are sourced from `/persist/etc`, as listed in [storage](storage.md#retained-paths). Keep the private host key root-owned `0600` and the public key `0644`. The initrd host key is separate; reinstall boot artifacts after changing its source, and verify the resulting fingerprint. Its inclusion in boot artifacts means it may reside on the unencrypted ESP.

Restore generated identities with their containing state: Synapse signing keys, MAS encryption/signing keys, Nextcloud instance configuration, Vaultwarden keys, Pleroma secrets/cookie and ACME account keys. Restoring database contents alone does not recover an application's identity or encrypted data.

Actual's client secret must match Authentik's registration; MAS's homeserver secret must match Synapse's integration configuration. MAS local passwords are disabled, so the upstream login configuration in its runtime YAML is required for authentication.

## Provisioning and access

Create `/persist/credentials` as `root:root 0700`. Stage new files privately outside the checkout with `umask 077`, then install them with explicit owner/group/mode. Provision boot credentials before installation/rebuild, and service credentials before starting their consumers. Use a service's actual runtime identity for static-reader files; avoid printing values in command arguments, journals or shared terminal recordings.

On a new installation, password hashes can be generated interactively with `mkpasswd --method=yescrypt`, SSH keys with `ssh-keygen`, and WireGuard keys with `wg genkey`. Generate unrelated secrets independently. On recovery, restore the existing values; generating replacements does not preserve access to the existing repository or encrypted application state.

For dynamic-user services, restore complete backing trees while stopped, retain an unchanged extracted copy, and let systemd manage state-directory access. Check credentials from the service's namespace with its sandbox settings in effect; host ownership listings alone can be misleading. Do not hard-code a historical dynamic UID or make the private parent directories traversable to other users.

Keep independently accessible copies of boot/repository credentials, verified SSH host fingerprints and application recovery material. Server backups include many of these files, but recovering the archive itself must not depend on a secret available only inside it.
