#!/usr/bin/env python3
"""Root-only verification, isolated from production incidents and probe inputs."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile


def load_module(path):
    spec = importlib.util.spec_from_file_location("apollo_alerts", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def health_tests(m, config):
    # Temporary fixtures and stubbed command output only; no SMTP or host probes.
    with tempfile.TemporaryDirectory(prefix="health-", dir=config["state"]) as directory:
        c = dict(config, state=directory, backupState=directory)
        now = [2000000000.0]
        a = m.Alerts(c, clock=lambda: now[0])
        a.freshness()
        assert a.status()["incidents"]["backup:freshness"]["active"]
        record = {"version": 1, "production": True, "runId": "20260913T120000Z-0123456789ab",
                  "capturedEpoch": now[0] - 31 * 3600, "uploadedEpoch": now[0]}
        record["archive"] = c["archivePrefix"] + "-" + record["runId"]
        m.atomic_json(Path(directory) / "last-success.json", record)
        a.freshness()
        assert a.status()["incidents"]["backup:freshness"]["active"]
        record["capturedEpoch"] = now[0] - 3600
        m.atomic_json(Path(directory) / "last-success.json", record)
        a.freshness()
        assert not a.status()["incidents"]["backup:freshness"]["active"]
        for value, expected in [(80, 1), (90, 2), (86, 2), (85, 1), (76, 1), (75, 0)]:
            a.capacity("capacity:test", value)
            assert a.status()["incidents"]["capacity:test"]["severity"] == expected
        for days, severity in [(20, 0), (14, 1), (7, 2), (-1, 2)]:
            assert m.certificate_severity(days) == severity
        for state, errors, expected in [("ONLINE", 0, 0), ("DEGRADED", 0, 2), ("ONLINE", 1, 2)]:
            assert m.zpool_health(f"rpool {state} 0 0 {errors}\nerrors: No known data errors")[0] == expected
        a.observe("synthetic", 1, "Synthetic failure")
        delivered = []
        a.deliver(transport=delivered.append)
        a.observe("synthetic", 1, "Repeated synthetic failure")
        assert not a.deliver(transport=delivered.append)
        now[0] += 86400
        assert a.deliver(transport=delivered.append)
        a.observe("synthetic", 0, "Synthetic recovery")
        assert a.deliver(transport=delivered.append)
        assert len(delivered) == 3
    print("PASS: isolated freshness, capacity, certificate, ZFS, reminder and recovery checks; no email sent.")


def main():
    os.umask(0o077)
    if os.geteuid() != 0:
        raise PermissionError("Run as root")
    c = json.loads(Path(sys.argv[1]).read_text())
    m = load_module(sys.argv[2])
    action = sys.argv[3] if len(sys.argv) == 4 else ""
    c["state"] += "/verification"
    a = m.Alerts(c)
    if action == "health":
        health_tests(m, c)
    elif action == "delivery-failure":
        if a.status()["pending"]:
            raise RuntimeError("Resolve the previous verification delivery first")
        a.observe("test:smtp-failure", 1, "Isolated SMTP outage/retry test; production incidents are separate.", once=True)
        # Worker treats a failed connection as a passed negative test.
        a.run("systemctl", "start", "apollo-alert-verify-failure.service", timeout=100)
        state = a.status()
        if not state.get("lastDeliveryError") or not state["pending"]:
            raise RuntimeError("Expected retained delivery failure was not observed")
        print("PASS: failed delivery is pending with sanitized diagnostics. Next: apollo-alert-verify delivery-retry")
    elif action == "worker-failure":
        if not os.environ.get("INVOCATION_ID"):
            raise RuntimeError("Use the supervised verification service")
        try:
            a.deliver(force=True)
        except (OSError, m.smtplib.SMTPException):
            return
        raise RuntimeError("Expected an isolated network failure")
    elif action == "delivery-retry":
        if not a.status()["pending"]:
            raise RuntimeError("No verification message is pending")
        a.run("systemctl", "start", "apollo-alert-verify-retry.service", timeout=100)
        if a.status()["pending"]:
            raise RuntimeError("Verification delivery remains pending")
        print("PASS: SMTP accepted the test message; confirm receipt at admin@ncrypt.at.")
    elif action == "worker-retry":
        a.deliver(force=True)
    elif action == "status":
        print(json.dumps(a.status(), indent=2))
    else:
        raise ValueError("Usage: apollo-alert-verify {health|delivery-failure|delivery-retry|status}")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Never print exception messages that can contain server responses.
        print("apollo-alert-verify: " + type(error).__name__, file=sys.stderr)
        sys.exit(1)
