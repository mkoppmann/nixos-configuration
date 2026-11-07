# Secrets and identities

[Repository overview](../README.md) · [Storage](storage.md) · [Recovery](recovery.md)

Secrets are provisioned manually at runtime paths. There is no secret-management module or automatic import of a checkout-local private directory. Keep secret values outside Git and Nix expressions: Nix-store files are normally readable by other users.

## Credential inventory

Paths below are configured readers or boot inputs. Files beneath persisted service trees have corresponding backing paths under `/persist`; see [storage](storage.md#retained-paths).

| Path | Format and consumer | Access requirement |
| --- | --- | --- |
| `/persist/credentials/user_mcp` | Password hash for `mcp`, not plaintext or a full shadow entry | `root:root 0600`; retain the actual sudo password independently |
| `/persist/credentials/initrd_host_ed25519_key` | Dedicated unencrypted Ed25519 SSH host key for initrd | `root:root 0600`; required when boot secrets are installed |
| `/persist/credentials/borg_sidechest_passphrase` | Raw passphrase for the existing Borg repository | `root:root 0600`; a new random value cannot unlock existing archives |
| `/persist/credentials/borg_sidechest_ssh` | Unencrypted SSH client key authorised on the Storage Box | `root:root 0600`; backup job supplies no interactive key passphrase |
| `/persist/credentials/reporting_smtp_password` | Raw single-line password for `reporting@ncrypt.at` | `root:root 0600`; loaded into the SMTP worker using systemd credentials |
| `/var/lib/wireguard/private_key` | WireGuard private key | Root-readable, `0600`; changing it requires peer coordination |
| `/var/lib/actual/openid_client_secret` | Raw secret for Actual's configured Authentik OIDC client | Dynamic `actual` reader, `0600` |
| `/persist/var/lib/authentik/authentik-env` | systemd environment file, including application secret and SMTP password | `root:root 0600`; preserve the original secret with the database |
| `/var/lib/matrix-synapse/secrets.yaml` | YAML merged into Synapse configuration | `matrix-synapse`-readable, `0600`; preserve every field and referenced file |
| `/var/lib/private/matrix-authentication-service/secrets.yaml` | YAML containing MAS encryption/signing keys, provider/client settings and SMTP password | Dynamic MAS reader, `0600` |
| `/var/lib/private/matrix-authentication-service/homeserver_secret` | Raw MAS/Synapse integration secret | Dynamic MAS reader, `0600`; match Synapse's runtime configuration |
| `/var/lib/nextcloud/secrets.json` | JSON merged into Nextcloud configuration, including SMTP credentials | Root-readable credential source, `0600` |
| `/var/lib/nextcloud/adminpass` | Raw password for initial creation of administrator `ncroot` | Root-readable credential source, `0600`; must remain nonempty for the setup service |
| `/var/lib/pleroma/secret.exs` | Elixir configuration imported by Pleroma | `pleroma`-readable, `0600`; preserve endpoint secrets, matching VAPID keys and overrides |
| `/var/lib/bitwarden_rs/.env` | systemd environment assignments, including deployed SMTP/admin credentials | `root:root 0600` |
| `/var/lib/acme/idp.ncrypt.at/fullchain.pem` and `key.pem` | ACME-managed certificate/key loaded by the Authentik worker | Preserve module-managed ownership and restrictive permissions |

Authentik's environment file uses names such as `AUTHENTIK_SECRET_KEY` and `AUTHENTIK_EMAIL__PASSWORD`. Environment-file syntax is not shell syntax; do not source these files. Preserve all fields in existing JSON/YAML/Elixir files rather than replacing them with minimal examples. The checkout cannot establish their complete contents.

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
