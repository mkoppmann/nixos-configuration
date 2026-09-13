"""Portable alert tests. No live SMTP, systemd, storage or certificate changes."""
import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import smtplib
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/alerts.py"
spec = importlib.util.spec_from_file_location("alerts", SCRIPT)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class AlertsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.now = 2000000000.0
        self.c = dict(state=self.temp.name, backupState=self.temp.name,
                      host="apollo", smtpHost="smtp.invalid", smtpPort=465,
                      smtpUser="test@example.invalid", sender="test@example.invalid",
                      recipient="admin@example.invalid", caFile="unused",
                      archivePrefix="apollo-sidechest", filesystems=[], certificates={})
        self.a = m.Alerts(self.c, clock=lambda: self.now,
                          run=lambda *args: self.fail("Unexpected host command"))
        self.messages = []

    def send(self):
        return self.a.deliver(transport=self.messages.append)

    def incident(self, key="test"):
        return self.a.status()["incidents"][key]

    def record(self, **overrides):
        record = dict(version=1, production=True, runId="20260913T120000Z-0123456789ab",
                      capturedEpoch=self.now - 3600, uploadedEpoch=self.now)
        record["archive"] = self.c["archivePrefix"] + "-" + record["runId"]
        record.update(overrides)
        m.atomic_json(Path(self.temp.name) / "last-success.json", record)

    def ledger(self, **record):
        m.atomic_json(Path(self.temp.name) / "run.json", record)

    def test_repeat_reminder_and_recovery(self):
        self.a.observe("test", 1, "failure")
        self.assertTrue(self.send())
        self.a.observe("test", 1, "changing measurement")
        self.now += 86399
        self.assertFalse(self.send())
        self.now += 1
        self.assertTrue(self.send())
        self.a.observe("test", 0, "recovered")
        self.assertTrue(self.send())
        self.assertFalse(self.send())
        self.assertEqual(len(self.messages), 3)

    def test_new_incident_and_escalation_are_immediate(self):
        self.a.observe("test", 1, "failure")
        self.send()
        self.a.observe("test", 2, "critical")
        self.assertTrue(self.send())
        self.a.observe("test", 1, "downgraded")
        self.assertFalse(self.send())
        self.a.observe("test", 2, "escalated again")
        self.assertTrue(self.send())
        self.a.observe("test", 0, "resolved")
        self.send()
        self.a.observe("test", 1, "recurrence")
        self.assertTrue(self.send())

    def test_failure_retry_and_recovery_before_delivery(self):
        self.a.observe("test", 1, "original failure")
        def failed(_):
            raise smtplib.SMTPAuthenticationError(535, b"secret password never print")
        with self.assertRaises(smtplib.SMTPAuthenticationError):
            self.a.deliver(transport=failed)
        self.assertIsNone(self.incident()["lastSent"])
        self.assertNotIn("secret password", json.dumps(self.a.status()))
        self.assertFalse(self.send())
        self.a.observe("test", 0, "recovered")
        self.now += 900
        self.assertTrue(self.send())
        body = self.messages[0].get_content()
        self.assertIn("FAILURE AND RECOVERY", body)
        self.assertIn("original failure", body)
        self.assertIn("recovered", body)

    def test_pending_and_suppression_survive_restart(self):
        self.a.observe("test", 1, "failure")
        self.a = m.Alerts(self.c, clock=lambda: self.now)
        self.assertTrue(self.send())
        self.a = m.Alerts(self.c, clock=lambda: self.now)
        self.assertFalse(self.send())

    def test_collection_during_smtp_and_changed_state(self):
        self.a.observe("test", 1, "failure")
        def transport(message):
            self.messages.append(message)
            self.a.observe("test", 0, "recovered during SMTP")
            self.a.observe("second", 2, "independent failure")
            self.assertFalse(self.a.deliver(transport=self.messages.append))
        self.a.deliver(transport=transport)
        self.assertEqual(set(self.a.status()["pending"]), {"test", "second"})
        self.assertTrue(self.send())

    def test_parallel_collectors_do_not_lose_incidents(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda n: self.a.observe(str(n), 1, "failure"), range(30)))
        self.assertEqual(len(self.a.status()["pending"]), 30)

    def test_delivery_crash_keeps_pending_and_retry_delay(self):
        self.a.observe("test", 1, "failure")
        with self.assertRaises(KeyboardInterrupt):
            self.a.deliver(transport=lambda _: (_ for _ in ()).throw(KeyboardInterrupt()))
        self.assertEqual(self.a.status()["pending"], ["test"])
        self.assertFalse(self.send())
        self.now += 900
        self.assertTrue(self.send())

    def test_private_modes_and_history_expiry(self):
        self.a.observe("test", 1, "failure")
        self.send()
        self.a.observe("test", 0, "recovered")
        self.send()
        for name in ("state.json", "state.lock", "delivery.lock"):
            self.assertEqual((Path(self.temp.name) / name).stat().st_mode & 0o777, 0o600)
        self.now += 31 * m.DAY
        self.assertEqual(self.a.status()["history"], [])
        self.assertEqual(self.a.status()["incidents"], {})

    def test_old_undelivered_incident_is_retained(self):
        self.a.observe("test", 1, "failure")
        self.a.observe("test", 0, "recovered")
        self.now += 31 * m.DAY
        self.assertEqual(self.a.status()["pending"], ["test"])

    def test_one_shot_test_has_no_reminder_or_recovery(self):
        self.a.observe("test", 1, "test message", once=True)
        self.send()
        self.now += 2 * m.DAY
        self.assertFalse(self.send())

    def test_acknowledgement_is_not_reported_as_recovery(self):
        self.a.observe("test", 2, "failure")
        self.send()
        self.a.acknowledge("test")
        self.send()
        self.assertIn("ACKNOWLEDGED", self.messages[-1].get_content())
        self.assertIn("recovery was not verified", self.messages[-1].get_content())

    def test_probe_failure_preserves_existing_health_incident(self):
        self.a.observe("capacity:rpool", 2, "full")
        self.assertFalse(self.a.probe("capacity:rpool", lambda: 1 / 0))
        self.assertEqual(self.incident("capacity:rpool")["severity"], 2)
        self.assertTrue(self.incident("monitoring:capacity:rpool")["active"])
        self.a.probe("capacity:rpool", lambda: None)
        self.assertFalse(self.incident("monitoring:capacity:rpool")["active"])

    def test_capacity_thresholds_and_hysteresis(self):
        for used, expected in [(79, 0), (80, 1), (90, 2), (89, 2), (85, 1), (76, 1), (75, 0)]:
            self.a.capacity("capacity:test", used)
            self.assertEqual(self.a.status()["incidents"].get("capacity:test", {}).get("severity", 0), expected)
        for invalid in (float("nan"), float("inf"), -1, 101):
            with self.assertRaises(ValueError):
                m.capacity_severity(invalid)

    def test_certificate_boundaries_and_parse(self):
        for days, expected in [(14.1, 0), (14, 1), (7, 2), (-1, 2)]:
            self.assertEqual(m.certificate_severity(days), expected)
        self.a.run = lambda *args: "notAfter=May 19 03:33:20 2033 GMT"  # now
        self.a.certificate("test", "/synthetic")
        self.assertEqual(self.incident("certificate:test")["severity"], 2)

    def test_zfs_health_and_error_counters(self):
        self.assertEqual(m.zpool_health("rpool ONLINE 0 0 0\nerrors: No known data errors")[0], 0)
        for row in ("rpool DEGRADED 0 0 0", "disk ONLINE 1 0 0", "disk ONLINE 0 0 3"):
            self.assertEqual(m.zpool_health(row + "\nerrors: No known data errors")[0], 2)
        self.assertEqual(m.zpool_health("rpool ONLINE 0 0 0\nerrors: 1 data errors")[0], 2)
        with self.assertRaises(ValueError):
            m.zpool_health("unexpected")

    def test_freshness_missing_stale_and_exact_boundary(self):
        self.a.freshness()
        self.assertTrue(self.incident("backup:freshness")["active"])
        self.record(capturedEpoch=self.now - 30 * 3600)
        self.a.freshness()
        self.assertFalse(self.incident("backup:freshness")["active"])
        self.now += 1
        self.a.freshness()
        self.assertTrue(self.incident("backup:freshness")["active"])

    def test_uploading_old_data_is_not_fresh(self):
        self.record(capturedEpoch=self.now - 48 * 3600)
        self.a.freshness()
        self.assertTrue(self.incident("backup:freshness")["active"])

    def test_invalid_evidence_is_probe_failure(self):
        for change in [dict(production=False), dict(archive="incomplete"),
                       dict(capturedEpoch=float("nan")), dict(uploadedEpoch=self.now + 3600)]:
            self.record(**change)
            with self.assertRaises(ValueError):
                self.a.freshness()

    def test_corrupt_state_is_not_silently_reset(self):
        path = Path(self.temp.name) / "state.json"
        path.write_text("broken")
        with self.assertRaises(json.JSONDecodeError):
            self.a.observe("test", 1, "failure")
        self.assertEqual(path.read_text(), "broken")

    def test_backup_failure_recovery_and_retention_are_separate(self):
        self.ledger(phase="failed", error="sensitive text", resumed=True)
        self.a.backup()
        self.assertTrue(self.incident(m.BACKUP_CAPTURE)["active"])
        self.assertNotIn("sensitive text", json.dumps(self.a.status()))
        self.ledger(phase="uploading", captureComplete=True, resumed=True, uploadError="prune failed")
        self.a.backup()
        self.assertFalse(self.incident(m.BACKUP_CAPTURE)["active"])
        self.assertTrue(self.incident(m.BACKUP_UPLOAD)["active"])
        self.ledger(phase="complete", resumed=True, retentionComplete=True, uploadError="old error")
        self.a.backup()
        self.assertFalse(self.incident(m.BACKUP_UPLOAD)["active"])

    def test_backup_test_run_does_not_resolve_production_incident(self):
        self.a.observe(m.BACKUP_CAPTURE, 2, "production failure")
        self.ledger(testCapture=True, phase="complete", resumed=True)
        self.a.backup()
        self.assertTrue(self.incident(m.BACKUP_CAPTURE)["active"])

    def test_old_success_ledger_cannot_resolve_new_unit_failure(self):
        self.ledger(id="old", phase="complete", resumed=True, retentionComplete=True)
        p = dict(ActiveState="failed", Result="exit-code", ExecMainStatus="1", start="boot:42")
        with patch.object(self.a, "unit_properties", return_value=p):
            self.a.unit("apollo-backup-upload.service")
        self.a.backup()
        self.assertTrue(self.incident(m.BACKUP_UPLOAD)["active"])
        self.ledger(id="new", phase="complete", resumed=True, retentionComplete=True)
        self.a.backup()
        self.assertFalse(self.incident(m.BACKUP_UPLOAD)["active"])

    def test_backup_recovery_deadline(self):
        self.ledger(maintenanceStarted=self.now - 601, resumed=False, restoreApplications=["app"])
        self.a.backup()
        self.assertTrue(self.incident(m.BACKUP_RECOVER)["active"])
        self.ledger(maintenanceStarted=self.now - 601, resumed=True)
        self.a.backup()
        self.assertFalse(self.incident(m.BACKUP_RECOVER)["active"])

    def test_unit_success_requires_new_invocation_not_reset_failed(self):
        p = dict(LoadState="loaded", ActiveState="failed", Result="exit-code", ExecMainStatus="1", start="boot:42")
        with patch.object(self.a, "unit_properties", return_value=p):
            self.a.unit("app.service")
            p.update(ActiveState="inactive", Result="success", ExecMainStatus="0", ExecMainCode="1",
                     ExecMainStartTimestampMonotonic="42")
            self.a.unit("app.service")
            self.assertTrue(self.incident("service:app.service")["active"])
            p.update(start="boot:43", ExecMainStartTimestampMonotonic="43")
            self.a.unit("app.service")
            self.assertFalse(self.incident("service:app.service")["active"])

    def test_automatic_restart_and_normal_stop_do_not_alert(self):
        for state in ("activating", "active", "inactive", "deactivating"):
            with patch.object(self.a, "unit_properties", return_value=dict(ActiveState=state, start="boot:42")):
                self.a.unit("app.service")
        self.assertFalse(self.a.status()["incidents"])

    def test_excluded_units_do_not_even_probe(self):
        self.a.unit("apollo-alert-send.service")
        self.a.unit("apollo-backup-test@dump.service")
        self.assertFalse(self.a.status()["incidents"])

    def test_invalid_unit_names_cannot_be_arguments(self):
        for unit in ("--all.service", "app;whoami.service", "../test.service"):
            with self.assertRaises(ValueError):
                self.a.unit_properties(unit)

    def test_smtp_tls_credentials_and_explicit_envelope(self):
        password_dir = Path(self.temp.name) / "credentials"
        password_dir.mkdir()
        (password_dir / "smtp-password").write_text("secret\n")
        message = m.EmailMessage()
        with patch.dict(os.environ, CREDENTIALS_DIRECTORY=str(password_dir)), \
             patch.object(m.ssl, "create_default_context", return_value="TLS context") as context, \
             patch.object(m.smtplib, "SMTP_SSL") as smtp:
            connection = smtp.return_value.__enter__.return_value
            connection.send_message.return_value = {}
            self.a.smtp(message)
            context.assert_called_once_with(cafile="unused")
            smtp.assert_called_once_with("smtp.invalid", 465, timeout=20, context="TLS context")
            connection.login.assert_called_once_with("test@example.invalid", "secret")
            connection.send_message.assert_called_once_with(message, from_addr=self.c["sender"], to_addrs=[self.c["recipient"]])

    def test_health_verification_uses_only_fixture_data(self):
        spec = importlib.util.spec_from_file_location("verify", SCRIPT.with_name("alert-verification.py"))
        verify = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(verify)
        verify.health_tests(m, self.c)


if __name__ == "__main__":
    unittest.main()
