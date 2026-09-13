#!/usr/bin/env python3
"""Apollo host-local alerts. Credentials are read only by the SMTP worker.

Operational commands require root. Probes and transport are injectable in tests;
the production CLI accepts no alternate config, state paths or health fixtures.
"""

import contextlib
import copy
import datetime as dt
from email.message import EmailMessage
import fcntl
import json
import math
import os
from pathlib import Path
import re
import smtplib
import ssl
import subprocess
import sys
import tempfile
import time
import uuid

DAY = 86400
RETRY = 900
UNIT = re.compile(r"[A-Za-z0-9_.@:\\-]+\.service\Z")
EXCLUDED = ("apollo-alert-", "apollo-backup-test@")
BACKUP_CAPTURE = "service:apollo-backup.service"
BACKUP_UPLOAD = "service:apollo-backup-upload.service"
BACKUP_RECOVER = "service:apollo-backup-recover.service"


def backup_evidence(run, key):
    if key == BACKUP_CAPTURE:
        return [run.get("id"), bool(run.get("captureComplete")), run.get("phase")]
    if key == BACKUP_UPLOAD:
        return [run.get("id"), bool(run.get("retentionComplete"))]
    return [run.get("id"), bool(run.get("resumed")),
            bool(run.get("restoreApplications") or run.get("restoreTimers"))]


def atomic_json(path, value):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, prefix=".write-", delete=False) as f:
            temporary = Path(f.name)
            json.dump(value, f, indent=2, sort_keys=True)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(temporary, path)
        fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def command(*args, timeout=20):
    return subprocess.run(args, check=True, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, timeout=timeout).stdout.strip()


def safe_error(exc):
    # Exception text may contain SMTP responses, addresses, subprocess data or
    # credentials. Persist only our own category and numeric protocol status.
    code = getattr(exc, "smtp_code", None)
    return type(exc).__name__ + (f" (SMTP {int(code)})" if isinstance(code, int) else "")


def capacity_severity(used, previous=0):
    if not math.isfinite(used) or not 0 <= used <= 100:
        raise ValueError("Invalid capacity")
    if used >= 90 or (previous == 2 and used > 85):
        return 2
    if used >= 80 or (previous >= 1 and used > 75):
        return 1
    return 0


def certificate_severity(days):
    if not math.isfinite(days):
        raise ValueError("Invalid expiry")
    return 2 if days <= 7 else 1 if days <= 14 else 0


def zpool_health(output):
    # zpool status -p emits exact integer error counts; no repair commands.
    devices = []
    errors = None
    for line in output.splitlines():
        columns = line.split()
        if len(columns) >= 5 and all(re.fullmatch(r"\d+", x) for x in columns[-3:]):
            devices.append((columns[-4], [int(x) for x in columns[-3:]]))
        if line.strip().startswith("errors:"):
            errors = line.strip() == "errors: No known data errors"
    if not devices or errors is None:
        raise ValueError("Unrecognized pool status")
    bad = sum(state != "ONLINE" or any(counts) for state, counts in devices)
    return (2 if bad or not errors else 0,
            f"rpool: {bad} unhealthy/error-bearing device rows; permanent errors: {not errors}")


class Alerts:
    def __init__(self, config, *, clock=time.time, run=command):
        self.c, self.clock, self.run = config, clock, run
        self.state = Path(config["state"])
        self.state.mkdir(mode=0o700, parents=True, exist_ok=True)

    @contextlib.contextmanager
    def transaction(self):
        with open(self.state / "state.lock", "a+") as lock:
            os.chmod(lock.name, 0o600)
            fcntl.flock(lock, fcntl.LOCK_EX)
            path = self.state / "state.json"
            data = json.loads(path.read_text()) if path.exists() else {
                "version": 1, "incidents": {}, "history": [], "deliveryNext": 0,
            }
            if data.get("version") != 1:
                raise ValueError("Unknown alert state version")
            self.prune(data)
            yield data
            self.prune(data)
            atomic_json(path, data)

    def prune(self, data):
        cutoff = self.clock() - 30 * DAY
        data["history"] = [h for h in data["history"] if h["time"] >= cutoff]
        data["incidents"] = {k: v for k, v in data["incidents"].items()
                             if v["active"] or self.due(v) or v["lastSeen"] >= cutoff}

    def history(self, data, key, event, detail):
        data["history"].append({"time": self.clock(), "key": key, "event": event, "detail": detail})

    def observe(self, key, severity, summary, **metadata):
        now = self.clock()
        with self.transaction() as data:
            item = data["incidents"].get(key)
            if item is None:
                if severity == 0:
                    return
                item = {"generation": 0, "active": False, "severity": 0,
                        "lastSent": None, "sentGeneration": -1, "sentActive": False,
                        "sentSeverity": 0, "firstSeen": now,
                        "escalation": 0, "sentEscalation": 0}
                data["incidents"][key] = item
            changed = item["active"] != bool(severity) or item["severity"] != severity
            if item["active"] and severity > item["severity"]:
                item["escalation"] = item.get("escalation", 0) + 1
            if severity and not item["active"]:
                item["generation"] += 1
                item["firstSeen"] = now
                item.pop("acknowledged", None)
                item["failureSummary"] = summary
            item.update(active=bool(severity), severity=severity, summary=summary, lastSeen=now)
            item.update(metadata)
            if changed:
                self.history(data, key, "observed", summary)

    def due(self, item):
        return (item["lastSent"] is None
                or item["generation"] != item["sentGeneration"]
                or item["active"] != item["sentActive"]
                or item["severity"] > item["sentSeverity"]
                or item.get("escalation", 0) > item.get("sentEscalation", 0)
                or (item["active"] and not item.get("once")
                    and self.clock() - item["lastSent"] >= DAY))

    def status(self):
        with self.transaction() as data:
            result = copy.deepcopy(data)
        result["pending"] = [k for k, v in result["incidents"].items() if self.due(v)]
        return result

    def acknowledge(self, key):
        with self.transaction() as data:
            item = data["incidents"][key]
            item.update(active=False, severity=0, acknowledged=True, lastSeen=self.clock(),
                        summary="Operator acknowledged/retired this incident; recovery was not verified.")
            self.history(data, key, "acknowledged", item["summary"])

    def probe(self, name, action):
        try:
            action()
        except Exception as exc:
            self.observe("monitoring:" + name, 1, "Probe failed: " + safe_error(exc))
            return False
        self.observe("monitoring:" + name, 0, "Probe is working again.")
        return True

    def unit_properties(self, unit):
        if not UNIT.fullmatch(unit) or unit.startswith("-"):
            raise ValueError("Invalid service name")
        output = self.run("systemctl", "show", unit,
                          "--property=LoadState,ActiveState,Result,ExecMainStatus,ExecMainCode,ExecMainStartTimestampMonotonic")
        properties = dict(line.split("=", 1) for line in output.splitlines() if "=" in line)
        properties["start"] = (Path("/proc/sys/kernel/random/boot_id").read_text().strip()
                               + ":" + properties.get("ExecMainStartTimestampMonotonic", "0"))
        return properties

    def unit(self, unit):
        if unit.startswith(EXCLUDED):
            return
        p = self.unit_properties(unit)
        canonical = "apollo-backup-upload.service" if unit == "borgbackup-job-sidechest.service" else unit
        key = "service:" + canonical
        if p.get("ActiveState") == "failed":
            # Only allow enumerated safe metadata into messages.
            result = p.get("Result", "unknown")
            if not re.fullmatch(r"[a-z-]+", result):
                result = "unknown"
            status = p.get("ExecMainStatus", "unknown")
            if not status.isdigit():
                status = "unknown"
            metadata = {}
            if key in (BACKUP_CAPTURE, BACKUP_UPLOAD, BACKUP_RECOVER):
                try:
                    ledger = json.loads((Path(self.c["backupState"]) / "run.json").read_text())
                    if ledger.get("testCapture"):
                        return
                    metadata["failedLedgerEvidence"] = backup_evidence(ledger, key)
                except (OSError, ValueError):
                    metadata["failedLedgerEvidence"] = None
            self.observe(key, 2, f"{unit}: failed; result={result}; exit status={status}.",
                         unit=canonical, failedStart=p["start"], **metadata)
        elif key not in (BACKUP_CAPTURE, BACKUP_UPLOAD, BACKUP_RECOVER):
            with self.transaction() as data:
                old = copy.deepcopy(data["incidents"].get(key))
            if (old and old["active"] and p.get("LoadState") == "loaded"
                    and p.get("Result") == "success"
                    and p["start"] != old.get("failedStart")
                    and p.get("ExecMainStartTimestampMonotonic", "0") != "0"
                    and (p.get("ActiveState") == "active"
                         or (p.get("ActiveState") == "inactive" and p.get("ExecMainCode") == "1"
                             and p.get("ExecMainStatus") == "0"))):
                self.observe(key, 0, f"{unit}: a subsequent invocation succeeded.")

    def units(self):
        units = json.loads(self.run("systemctl", "list-units", "--all", "--type=service", "--output=json"))
        tracked = self.status()["incidents"].values()
        names = {u["unit"] for u in units if u["active"] == "failed"}
        names.update(v["unit"] for v in tracked if v["active"] and "unit" in v)
        for name in sorted(names):
            self.probe("unit:" + name, lambda name=name: self.unit(name))

    def capacity(self, key, used):
        old = self.status()["incidents"].get(key, {}).get("severity", 0)
        self.observe(key, capacity_severity(used, old), f"{key}: {used:.1f}% used.")

    def filesystem(self, path):
        # A missing mount must not be mistaken for a healthy parent filesystem.
        self.run("findmnt", "--mountpoint", path, "--noheadings", "--output", "TARGET")
        usage = os.statvfs(path)
        available = usage.f_bavail
        used = usage.f_blocks - usage.f_bfree
        self.capacity("capacity:" + path, 100 * used / (used + available))

    def freshness(self):
        path = Path(self.c["backupState"]) / "last-success.json"
        if not path.exists():
            self.observe("backup:freshness", 2, "No successful production archive is recorded (including deployment holds).")
            return
        record = json.loads(path.read_text())
        captured, uploaded = record["capturedEpoch"], record["uploadedEpoch"]
        if (record.get("version") != 1 or record.get("production") is not True
                or not re.fullmatch(r"\d{8}T\d{6}Z-[0-9a-f]{12}", record["runId"])
                or record["archive"] != self.c["archivePrefix"] + "-" + record["runId"]
                or not all(isinstance(v, (int, float)) and math.isfinite(v) for v in (captured, uploaded))
                or not 0 < captured <= uploaded <= self.clock() + 300):
            raise ValueError("Invalid production success evidence")
        hours = (self.clock() - captured) / 3600
        self.observe("backup:freshness", 2 if hours > 30 else 0,
                     f"Latest uploaded production data is {hours:.1f} hours old; limit is 30 hours.")

    def backup(self):
        path = Path(self.c["backupState"]) / "run.json"
        if not path.exists():
            return
        run = json.loads(path.read_text())
        if run.get("testCapture"):
            return
        def failure(key, summary):
            self.observe(key, 2, summary, failedLedgerEvidence=backup_evidence(run, key))

        def recovered(key, summary):
            old = self.status()["incidents"].get(key, {})
            # An old successful ledger cannot resolve a newer failed unit or a
            # successful timer no-op. Require changed production evidence.
            if old.get("failedLedgerEvidence") != backup_evidence(run, key):
                self.observe(key, 0, summary)

        if run.get("phase") == "failed" or (run.get("error") and not run.get("captureComplete")
                                            and run.get("phase") != "complete"):
            failure(BACKUP_CAPTURE, "Production capture failed or was discarded; inspect apollo-backup-status.")
        elif ((run.get("captureComplete") and run.get("resumed")) or run.get("phase") == "complete"):
            recovered(BACKUP_CAPTURE, "A production capture succeeded and applications resumed.")
        if run.get("uploadError") and not run.get("retentionComplete"):
            failure(BACKUP_UPLOAD, "Production archive upload or retention failed; inspect apollo-backup-status.")
        elif run.get("retentionComplete"):
            recovered(BACKUP_UPLOAD, "Production archive upload and retention succeeded.")
        pending = bool(run.get("restoreApplications") or run.get("restoreTimers") or
                       (run.get("maintenanceStarted") and not run.get("resumed")))
        if pending and self.clock() - run.get("maintenanceStarted", self.clock()) > 600:
            failure(BACKUP_RECOVER, "Production application recovery exceeded the 600-second maintenance budget.")
        elif run.get("resumed") and not pending:
            recovered(BACKUP_RECOVER, "Production application recovery completed.")

    def certificate(self, name, path):
        output = self.run("openssl", "x509", "-in", path, "-noout", "-enddate")
        expires = dt.datetime.strptime(output.removeprefix("notAfter="), "%b %d %H:%M:%S %Y %Z").replace(tzinfo=dt.timezone.utc)
        days = (expires.timestamp() - self.clock()) / DAY
        self.observe("certificate:" + name, certificate_severity(days), f"{name}: certificate expires in {days:.1f} days.")

    def check(self):
        self.probe("services", self.units)
        self.probe("backup-freshness", self.freshness)
        self.probe("backup-state", self.backup)
        self.probe("capacity:rpool", lambda: self.capacity("capacity:rpool", float(
            self.run("zpool", "list", "-H", "-p", "-o", "capacity", "rpool").rstrip("%"))))
        self.probe("zfs-health", lambda: self.observe("storage:rpool", *zpool_health(
            self.run("zpool", "status", "-p", "rpool"))))
        for path in self.c["filesystems"]:
            self.probe("capacity:" + path, lambda path=path: self.filesystem(path))
        for name, path in self.c["certificates"].items():
            self.probe("certificate:" + name, lambda name=name, path=path: self.certificate(name, path))

    def smtp(self, message):
        password = (Path(os.environ["CREDENTIALS_DIRECTORY"]) / "smtp-password").read_text().removesuffix("\n")
        if not password or "\n" in password or "\r" in password:
            raise ValueError("Invalid password file")
        with smtplib.SMTP_SSL(self.c["smtpHost"], self.c["smtpPort"], timeout=20,
                              context=ssl.create_default_context(cafile=self.c["caFile"])) as smtp:
            smtp.login(self.c["smtpUser"], password)
            refused = smtp.send_message(message, from_addr=self.c["sender"], to_addrs=[self.c["recipient"]])
            if refused:
                raise RuntimeError("Recipient refused")

    def deliver(self, transport=None, force=False):
        # A separate worker lock prevents duplicate concurrent sends. Collection
        # remains available throughout DNS, TLS and SMTP operations.
        with open(self.state / "delivery.lock", "a+") as worker:
            os.chmod(worker.name, 0o600)
            try:
                fcntl.flock(worker, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return False
            with self.transaction() as data:
                if not force and self.clock() < data["deliveryNext"]:
                    return False
                batch = {k: copy.deepcopy(v) for k, v in data["incidents"].items() if self.due(v)}
                if not batch:
                    return False
                # Also survives a worker timeout or crash before SMTP returns.
                data["deliveryNext"] = self.clock() + RETRY
                data["lastAttempt"] = self.clock()
            message = EmailMessage()
            message["From"], message["To"] = self.c["sender"], self.c["recipient"]
            message["Subject"] = f"[Apollo alerts] {self.c['host']}: {len(batch)} notification(s)"
            message["Date"] = dt.datetime.fromtimestamp(self.clock(), dt.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
            lines = [f"Host: {self.c['host']}", ""]
            for key, item in batch.items():
                label = ("ACKNOWLEDGED" if item.get("acknowledged") else "TEST" if item.get("once") else
                         "CRITICAL" if item["severity"] == 2 else "WARNING" if item["active"] else
                         "FAILURE AND RECOVERY" if item["generation"] != item["sentGeneration"] else "RECOVERY")
                lines.extend([f"{label}: {key}", item["summary"],
                              "First observed: " + dt.datetime.fromtimestamp(item["firstSeen"], dt.timezone.utc).isoformat(),
                              "Last observed: " + dt.datetime.fromtimestamp(item["lastSeen"], dt.timezone.utc).isoformat()])
                if not item["active"] and item.get("failureSummary"):
                    lines.append("Original failure: " + item["failureSummary"])
                if item.get("unit"):
                    lines.append(f"Inspect: sudo journalctl -u {item['unit']} --since today")
                lines.extend(["Inspect: sudo apollo-alert status", "Inspect backups: sudo apollo-backup-status", ""])
            message.set_content("\n".join(lines))
            try:
                (transport or self.smtp)(message)
            except Exception as exc:
                detail = safe_error(exc)
                with self.transaction() as data:
                    data["lastDeliveryError"] = detail
                    self.history(data, "delivery", "failed", detail)
                print("apollo-alert: delivery failed: " + detail, flush=True)
                raise
            with self.transaction() as data:
                for key, sent in batch.items():
                    item = data["incidents"][key]
                    item.update(lastSent=self.clock(), sentGeneration=sent["generation"],
                                sentActive=sent["active"], sentSeverity=sent["severity"],
                                sentEscalation=sent.get("escalation", 0))
                    if sent.get("once"):
                        item.update(active=False, severity=0, sentActive=False, sentSeverity=0)
                    self.history(data, key, "delivered", sent["summary"])
                data["lastDeliveryError"] = None
                data["lastDeliverySuccess"] = self.clock()
                data["deliveryNext"] = 0
            return True


def main():
    os.umask(0o077)
    if os.geteuid() != 0:
        raise PermissionError("Run as root")
    config = json.loads(Path(sys.argv[1]).read_text())
    alerts = Alerts(config)
    action, *args = sys.argv[2:]
    if action == "status" and not args:
        print(json.dumps(alerts.status(), indent=2, sort_keys=True))
    elif action == "check" and not args:
        alerts.check()
        alerts.run("systemctl", "start", "--no-block", "apollo-alert-send.service")
    elif action == "observe" and len(args) == 1:
        alerts.unit(args[0] + ".service")
        alerts.run("systemctl", "start", "--no-block", "apollo-alert-send.service")
    elif action == "send-test" and not args:
        alerts.observe("test:" + uuid.uuid4().hex, 1, "Manual Apollo email delivery test.", once=True)
        alerts.run("systemctl", "start", "apollo-alert-send.service", timeout=100)
    elif action == "retry" and not args:
        with alerts.transaction() as data:
            data["deliveryNext"] = 0
        alerts.run("systemctl", "start", "apollo-alert-send.service", timeout=100)
    elif action == "deliver" and not args:
        alerts.deliver()
    elif action == "acknowledge" and len(args) == 1:
        alerts.acknowledge(args[0])
    else:
        raise ValueError("Usage: apollo-alert {status|check|send-test|retry|acknowledge KEY}")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("apollo-alert: " + safe_error(error), file=sys.stderr)
        sys.exit(1)
