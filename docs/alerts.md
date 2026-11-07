# Email alerts

[Repository overview](../README.md) · [Backups](backups.md) · [Secrets](secrets.md)

The [alert module](../modules/alerts.nix) installs the [collector/delivery program](../scripts/alerts.py), timers and system-wide service failure hooks. Collection records terminal system-service failures immediately; health reconciliation runs every five minutes, starting five minutes after boot. The sender runs every minute after its initial five-minute boot delay.

## Health policy

| Condition | Policy |
| --- | --- |
| System-service failure | First email after 30 minutes if still unresolved; repeated observations do not extend the delay |
| Production capture/upload/retention failure | Tracked with production ledger evidence; 30-minute service grace |
| Backup application recovery | Immediate on recovery-service failure or unfinished recovery beyond the 600-second maintenance budget |
| Backup freshness | Critical if no successful production upload is recorded or its captured data is over 30 hours old |
| Pool/filesystem capacity | Warning at 80%, critical at 90%; critical clears at 85% or below, warning at 75% or below |
| ZFS health | Unhealthy pool/device state, nonzero read/write/checksum errors, or permanent errors |
| ACME certificates | Warning at 14 days or less to expiry, critical at 7 days or less |
| Probe failure | Monitoring incident; failed inspection does not count as a healthy result |

Capacity checks cover `rpool` and the actual mounts `/`, `/nix`, `/persist`, `/var/log`, `/boot`. Certificate checks inspect configured local ACME certificate files. Freshness uses capture time from `last-success.json`, not upload time; uploading old data does not make it fresh. Deployment holds do not suppress this check.

## Delivery and incident lifecycle

| Setting | Value |
| --- | --- |
| SMTP | `smtp.webspace.bz:465`, implicit TLS with CA and hostname verification |
| Sender / login | `reporting@ncrypt.at` |
| Recipient | `admin@ncrypt.at` |
| Password source | `/persist/credentials/reporting_smtp_password`, loaded through systemd credentials |
| Failed delivery | Durable retry eligibility after 15 minutes; picked up by the one-minute sender |
| Reminders | Daily for unresolved incidents |
| Local retention | 30 days for sanitized history and completed incidents; pending/unresolved incidents retained |

Pending notifications share one email per attempt. Stable incident keys deduplicate changing measurements. The sender rechecks eligible service failures and production backup evidence before mailing. A service that recovers before its first email remains in local history without failure/recovery mail. Once a service failure has been mailed, verified recovery is emailed; other health incidents can report a combined failure/recovery if they resolve before delivery.

A cleared failed flag alone does not prove service recovery. Generic service recovery requires a subsequent successful invocation; backup recovery uses changed production ledger evidence. If systemd reports a tracked service missing, the incident is retired without claiming verified recovery. Operator acknowledgement likewise records that recovery was not verified. New failure evidence can reopen an incident.

State lives in `/persist/var/lib/apollo-alerts` (`root:root 0700`, private files `0600`) and is included in Borg. Alert-service and supervised backup-test hooks are excluded to prevent recursive reporting. This host-local monitor cannot report while Apollo is down or unable to deliver mail.

## Operator commands

```bash
sudo apollo-alert status
# Reconcile current health and request delivery of eligible messages.
sudo apollo-alert check
sudo journalctl -u apollo-alert-check.service -u apollo-alert-send.service \
  --since '1 day ago'
```

The following actions send mail or change incident handling:

```bash
# Sends an explicit test message to admin@ncrypt.at.
sudo apollo-alert send-test
# Clears the delivery retry delay and attempts pending mail immediately.
sudo apollo-alert retry
# Replace the placeholder with a key shown by status.
sudo apollo-alert acknowledge 'REPLACE_WITH_INCIDENT_KEY'
```

Provision the SMTP password using the [credential inventory](secrets.md#credential-inventory). Delivery reads it only in the systemd worker; it is not embedded in Nix or the collector. Inspect the journal and durable status after a failed attempt; restarting timers or deleting state is not a substitute for resolving delivery errors. `apollo-alert-verify` provides isolated health/delivery verification state, separate from production incidents; delivery verification can send a real test email.
