# Monitoring

[Repository overview](../README.md) · [Backups](backups.md) · [Secrets](secrets.md)

The [monitoring module](../modules/system/monitoring.nix) reports problems by mail to `admin@ncrypt.at`. Mail goes through msmtp with `reporting@ncrypt.at` at `smtp.webspace.bz:465`; the password is the sops secret `reporting_smtp_password`.

| Source | Reports |
| --- | --- |
| Any systemd service entering the failed state | Mail from `notify-failure@UNIT.service` with the unit’s status and last 30 journal lines |
| ZFS event daemon | Pool and device errors and finished scrubs (monthly) |
| `disk-space-check.timer`, daily | Fails, and so mails, while `rpool` or `/boot` is more than 80% full |
| `authentik-update-check.timer`, daily | Fails, and so mails, while authentik-nix offers another Authentik release than the pinned one |
| `pinned-inputs-check.timer`, Mondays | Fails, and so mails, while the pinned flake inputs are behind their branches; lists the newest commits |
| `pending-reboot-check.timer`, Mondays | Fails, and so mails, while the booted kernel, kernel modules, initrd or boot parameters differ from the current system’s, which only a reboot applies |
| `zfs-rollback-check.service`, at boot | Fails, and so mails, when the root dataset was not rolled back |
| healthchecks.io | The nightly backup and a heartbeat every five minutes; alerts when a ping is late |

A service restarted by `Restart=` only fails once its restart limit is hit. ACME renewals report through their failing `acme-*.service` units.

Apollo cannot report its own outage. healthchecks.io notices missing pings when Apollo is down, offline or its mail is broken, and notifies through channels configured there, independent of Apollo. Its ping URLs are the sops secrets `healthchecks_backup_url` and `healthchecks_heartbeat_url`.

## Commands

```bash
# Send a test mail through the same path.
printf 'Subject: Test\n\nTest\n' | sudo msmtp admin@ncrypt.at
# Simulate a failure report.
sudo systemctl start notify-failure@test.service
journalctl -u 'notify-failure@*' --since today
```
