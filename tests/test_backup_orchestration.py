"""Portable state-machine tests: no systemd, PostgreSQL, ZFS or Borg invoked."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/backup-orchestration.py"
spec = importlib.util.spec_from_file_location("orchestration", SCRIPT)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class FakeRunner:
    def __init__(self, config, base):
        self.config, self.base = config, base
        self.calls, self.snapshots, self.owners, self.mounts, self.archives = [], set(), {}, {}, set()
        self.fail, self.free = None, 40
        self.states = {u: "active" for u in config["applications"] + config["timers"]}
        self.states["inactive.service"] = "inactive"
        self.active_jobs, self.start_failures = set(), set()

    def run(self, args, **kwargs):
        self.calls.append(args)
        if self.fail and self.fail(args):
            raise m.BackupError("injected command failure")
        if args[:2] == ["systemctl", "show"]:
            unit = args[2]
            state = self.states.get(unit, "inactive")
            if unit.startswith("postgresql"):
                state = "active"
            pid = "42" if unit in self.active_jobs else "0"
            return f"LoadState=loaded\nActiveState={state}\nMainPID={pid}\nControlPID=0\nControlGroup=\nResult=success"
        if args[:2] == ["systemctl", "list-jobs"]:
            return ""
        if args[0] == "systemctl" and args[1] in ("start", "stop"):
            for unit in args[2:]:
                if unit.endswith((".service", ".timer")):
                    self.states[unit] = "active" if args[1] == "start" and unit not in self.start_failures else "inactive"
            return ""
        if args[0] == "zpool":
            return f"100 {self.free}"
        if args[0] == "findmnt":
            target = args[-1]
            if "--submounts" in args:
                return target
            return self.mounts.get(target, self.config["datasets"].get(target.lstrip("/"), ""))
        if args[:2] == ["zfs", "list"]:
            return "\n".join(sorted(self.snapshots)) if "snapshot" in args else args[-1]
        if args[:2] == ["zfs", "snapshot"]:
            owner = args[3].split("=", 1)[1]
            for snapshot in args[4:]:
                self.snapshots.add(snapshot)
                self.owners[snapshot] = owner
            copy = self.base / "snapshot-data"
            if copy.exists():
                shutil.rmtree(copy)
            shutil.copytree(self.config["dumpDirectory"], copy)
            return ""
        if args[:2] == ["zfs", "get"]:
            return self.owners.get(args[-1], "foreign")
        if args[:2] == ["zfs", "destroy"]:
            self.snapshots.remove(args[-1])
            return ""
        if args[:2] == ["mount", "--bind"]:
            source, target = args[2:]
            relative, name = source.lstrip("/").split("/.zfs/snapshot/")
            self.mounts[target] = self.config["datasets"][relative] + "@" + name
            if relative == "persist":
                destination = Path(target) / self.config["dumpDirectory"].lstrip("/")
                if destination.exists():
                    shutil.rmtree(destination)
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copytree(self.base / "snapshot-data", destination)
            return ""
        if args[0] == "mount":
            return ""
        if args[0] == "umount":
            self.mounts.pop(args[1])
            return ""
        if args[0] == "runuser":
            if "psql" in args:
                return "\n".join(self.config["databases"] + ["postgres"])
            kwargs["stdout"].write(b"private test export\n")
            return ""
        if args[0] == "pg_restore":
            return ""
        if args[0] == "borg":
            operation = args[3]
            if operation == "list":
                return "\n".join(sorted(self.archives))
            if operation == "create":
                self.archives.add(args[-3][2:])
            if operation == "rename":
                self.archives.remove(args[-2][2:])
                self.archives.add(args[-1])
            if operation == "delete":
                self.archives.remove(args[-1][2:])
            return ""
        raise AssertionError(f"Unstubbed command: {args}")


class BackupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.c = {
            "state": str(self.base / "state"), "runtime": str(self.base / "run"),
            "dumpDirectory": str(self.base / "dumps"), "pgPort": "5432",
            "datasets": {"persist": "rpool/safe/persist", "var/log": "rpool/safe/log"},
            "applications": ["app.service", "worker.service", "inactive.service"],
            "jobs": ["cron.service"], "migrations": ["migration.service"],
            "timers": ["cron.timer"], "databases": ["first", "second", "onlyoffice"],
            "captureSeconds": 480, "resumeSeconds": 120, "minimumFreePercent": 10,
            "borg": {"prefix": "apollo-sidechest", "compression": "auto,zstd",
                     "keep": {"daily": 7, "weekly": 4, "monthly": 6},
                     "exclude": ["pp:persist/var/lib/postgresql", "sh:**/.zfs"]},
        }
        for name in ("state", "runtime", "dumpDirectory"):
            Path(self.c[name]).mkdir()
        (Path(self.c["dumpDirectory"]) / "globals").mkdir(mode=0o700)
        for lock in ("operation.lock", "recovery.lock"):
            (Path(self.c["runtime"]) / lock).touch()
        self.runner = FakeRunner(self.c, self.base)
        self.backup = m.Backup(self.c, self.runner)
        samefile = os.path.samefile
        for mock in (
            patch.object(m, "boot_id", return_value="test-boot"),
            patch.object(m.pwd, "getpwnam", return_value=SimpleNamespace(pw_uid=os.getuid(), pw_gid=os.getgid())),
            patch.object(m.os.path, "samefile", side_effect=lambda a, b: True if str(b).startswith("/persist/") else samefile(a, b)),
            patch.object(m.os.path, "ismount", side_effect=lambda p: str(p) in self.runner.mounts),
            patch.object(self.backup, "log"),
        ):
            mock.start()
            self.addCleanup(mock.stop)

    def assert_resumed(self):
        run = self.backup.load()
        self.assertTrue(run["resumed"])
        self.assertEqual(run["restoreApplications"], [])
        self.assertEqual(self.runner.states["app.service"], "active")
        self.assertEqual(self.runner.states["inactive.service"], "inactive")
        self.assertEqual(self.runner.states["cron.timer"], "active")
        self.assertFalse((self.backup.runtime / "quiescing").exists())
        self.assertFalse((self.backup.runtime / "maintenance").exists())

    def test_capture_resume_upload_and_original_paths(self):
        self.backup.capture()
        self.assert_resumed()
        snapshot_index = next(i for i, a in enumerate(self.runner.calls) if a[:2] == ["zfs", "snapshot"])
        restart_index = next(i for i, a in enumerate(self.runner.calls) if a[:2] == ["systemctl", "start"])
        self.assertLess(snapshot_index, restart_index)
        self.assertFalse(any(a[0] == "borg" for a in self.runner.calls))
        self.assertEqual(self.backup.load()["manifest"]["databases"], self.c["databases"])
        dumps = [a for a in self.runner.calls if "pg_dump" in a]
        self.assertEqual(len(dumps), len(self.c["databases"]))
        self.assertTrue(all("--format=custom" in a and "--compress=0" in a for a in dumps))
        messages = "\n".join(call.args[0] for call in self.backup.log.call_args_list)
        for relative in self.backup.load()["manifest"]["files"]:
            self.assertIn(f"{relative}: dump and sync started", messages)
            self.assertRegex(messages, rf"{relative}: dump and sync completed in \d+\.\d{{3}} seconds")
            self.assertRegex(messages, rf"{relative}: validation and checksum completed in \d+\.\d{{3}} seconds")
            self.assertRegex(messages, rf"{relative}: publication completed in \d+\.\d{{3}} seconds")
        self.assertIn("capture.json: publication completed", messages)
        self.assertNotIn("private test export", messages)
        self.backup.upload()
        run = self.backup.load()
        self.assertEqual(run["phase"], "complete")
        self.assertTrue(run["archiveCreated"] and run["retentionComplete"])
        self.assertFalse(self.runner.snapshots or self.runner.mounts)
        create = next(a for a in self.runner.calls if a[0] == "borg" and a[3] == "create")
        self.assertEqual(create[-2:], ["persist", "var/log"])
        self.assertIn("pp:persist/var/lib/postgresql", create)
        self.assertIn("apollo-incomplete-", create[-3])
        self.assertTrue(all("onlyoffice.service" not in a and "rabbitmq.service" not in a for a in self.runner.calls))

    def test_failed_dump_cannot_publish_old_exports(self):
        target = Path(self.c["dumpDirectory"]) / "first.sql"
        target.write_bytes(b"old export")
        self.runner.fail = lambda a: a[0] == "runuser" and "--dbname=second" in a
        with self.assertRaises(m.BackupError):
            self.backup.capture()
        self.assert_resumed()
        self.assertEqual(self.backup.load()["phase"], "failed")
        self.assertEqual(target.read_bytes(), b"old export")
        self.assertFalse(self.runner.snapshots)
        self.backup.upload()
        self.assertFalse(any(a[0] == "borg" for a in self.runner.calls))

    def test_checksum_deadline_reports_export_and_recovers_without_publication(self):
        target = Path(self.c["dumpDirectory"]) / "first.sql"
        target.write_bytes(b"old export")
        original = self.runner.run

        def run(args, **kwargs):
            result = original(args, **kwargs)
            if args[0] == "pg_restore":
                self.backup.deadline = time.monotonic() - 1
            return result

        with patch.object(self.runner, "run", side_effect=run):
            with self.assertRaisesRegex(m.BackupError, "Capture deadline reached during dump validation"):
                self.backup.capture()
        self.assert_resumed()
        self.assertEqual(self.backup.load()["phase"], "failed")
        self.assertEqual(target.read_bytes(), b"old export")
        self.assertFalse(self.runner.snapshots)
        self.assertEqual(list(Path(self.c["dumpDirectory"]).glob(".capture-*")), [])
        messages = "\n".join(call.args[0] for call in self.backup.log.call_args_list)
        self.assertIn("first.sql: validation and checksum failed after", messages)
        self.assertNotIn("second.sql: dump and sync started", messages)
        self.backup.external_recover()
        self.assertEqual(self.backup.load()["phase"], "failed")
        self.backup.upload()
        self.assertFalse(any(a[0] == "borg" for a in self.runner.calls))

    def test_empty_export_and_unreadable_archive_fail(self):
        original = self.runner.run
        for failure in ("empty", "unreadable"):
            with self.subTest(failure=failure):
                def run(args, **kwargs):
                    if args[0] == "runuser" and "psql" not in args and failure == "empty":
                        return ""
                    if args[0] == "pg_restore" and failure == "unreadable":
                        raise m.BackupError("invalid archive")
                    return original(args, **kwargs)
                with patch.object(self.runner, "run", side_effect=run):
                    with self.assertRaises(m.BackupError):
                        self.backup.capture()
                self.assert_resumed()
                self.assertFalse(self.backup.load()["captureComplete"])

    def test_snapshot_failure_and_cancellation_resume(self):
        for failure in (m.BackupError("snapshot failed"), KeyboardInterrupt()):
            with self.subTest(failure=type(failure)):
                with patch.object(self.backup, "take_snapshots", side_effect=failure):
                    with self.assertRaises(m.BackupError):
                        self.backup.capture()
                self.assert_resumed()

    def test_active_migration_skips_before_any_pause(self):
        self.runner.active_jobs.add("migration.service")
        with self.assertRaisesRegex(m.BackupError, "migration"):
            self.backup.capture()
        self.assertFalse(self.backup.ledger.exists())
        self.assertFalse(any(a[:2] == ["systemctl", "stop"] for a in self.runner.calls))

    def test_active_job_drains_without_stop_or_restart(self):
        self.runner.active_jobs.add("cron.service")
        with patch.object(self.backup, "pause", side_effect=lambda: self.runner.active_jobs.clear()):
            self.backup.capture()
        changes = [a for a in self.runner.calls if a[:2] in (["systemctl", "stop"], ["systemctl", "start"])]
        self.assertFalse(any("cron.service" in a for a in changes))

    def test_drain_deadline_aborts_and_restores_timers(self):
        self.runner.active_jobs.add("cron.service")
        with patch.object(self.backup, "pause", side_effect=m.BackupError("deadline")):
            with self.assertRaisesRegex(m.BackupError, "deadline"):
                self.backup.capture()
        self.assert_resumed()
        self.assertFalse(self.runner.snapshots)

    def test_operation_lock_excludes_capture_and_upload(self):
        with m.locked(self.backup.runtime / "operation.lock"):
            with self.assertRaises(m.Busy):
                self.backup.capture()
            with self.assertRaises(m.Busy):
                self.backup.upload()
        self.assertFalse(any(a[:2] == ["systemctl", "stop"] for a in self.runner.calls))

    def test_upload_failure_keeps_capture_and_retry_does_not_pause(self):
        self.backup.capture()
        capture_id = self.backup.load()["id"]
        count = len(self.runner.calls)
        self.runner.fail = lambda a: a[0] == "borg" and a[3] == "create"
        with self.assertRaises(m.BackupError):
            self.backup.upload()
        self.assertTrue(self.runner.snapshots)
        self.assertFalse(self.runner.mounts)
        self.runner.fail = None
        self.backup.upload()
        self.assertEqual(self.backup.load()["id"], capture_id)
        self.assertFalse(any(a[:2] == ["systemctl", "stop"] for a in self.runner.calls[count:]))

    def test_prune_failure_does_not_create_duplicate_archive(self):
        self.backup.capture()
        self.runner.fail = lambda a: a[0] == "borg" and a[3] == "prune"
        with self.assertRaises(m.BackupError):
            self.backup.upload()
        self.assertTrue(self.backup.load()["archiveCreated"])
        self.runner.fail = None
        self.backup.upload()
        self.assertEqual(sum(a[0] == "borg" and a[3] == "create" for a in self.runner.calls), 1)

    def test_production_success_evidence_survives_next_capture(self):
        self.backup.capture()
        run = self.backup.load()
        self.backup.upload()
        path = self.backup.state / "last-success.json"
        evidence = json.loads(path.read_text())
        self.assertEqual(evidence["capturedEpoch"], run["createdEpoch"])
        self.assertEqual(evidence["runId"], run["id"])
        self.assertTrue(evidence["production"])
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.backup.capture()
        self.assertEqual(json.loads(path.read_text()), evidence)

    def test_failed_upload_and_noop_do_not_create_success_evidence(self):
        path = self.backup.state / "last-success.json"
        self.backup.upload()
        self.assertFalse(path.exists())
        self.backup.capture()
        self.runner.fail = lambda a: a[0] == "borg" and a[3] == "create"
        with self.assertRaises(m.BackupError):
            self.backup.upload()
        self.assertFalse(path.exists())

    def test_prune_failure_keeps_valid_archive_evidence(self):
        self.backup.capture()
        self.runner.fail = lambda a: a[0] == "borg" and a[3] == "prune"
        with self.assertRaises(m.BackupError):
            self.backup.upload()
        path = self.backup.state / "last-success.json"
        evidence = path.read_bytes()
        self.runner.fail = None
        self.backup.upload()
        self.assertEqual(path.read_bytes(), evidence)

    def test_test_archive_never_writes_production_evidence(self):
        self.backup.testing = True
        self.backup.capture()
        self.backup.upload()
        self.assertFalse((self.backup.state / "last-success.json").exists())

    def test_crash_reconciled_archive_writes_success_evidence(self):
        self.backup.capture()
        run = self.backup.load()
        self.runner.archives.add(self.c["borg"]["prefix"] + "-" + run["id"])
        self.backup.upload()
        self.assertTrue((self.backup.state / "last-success.json").exists())
        self.assertFalse(any(a[0] == "borg" and a[3] == "create" for a in self.runner.calls))

    def test_older_archive_does_not_replace_newer_success_evidence(self):
        self.backup.capture()
        self.backup.upload()
        run = self.backup.load()
        path = self.backup.state / "last-success.json"
        evidence = path.read_bytes()
        run["createdEpoch"] -= 86400
        self.backup.record_archive_success(run)
        self.assertEqual(path.read_bytes(), evidence)

    def test_success_evidence_write_failure_keeps_capture_for_retry(self):
        self.backup.capture()
        atomic = m.atomic_json
        def fail_evidence(path, value):
            if Path(path).name == "last-success.json":
                raise OSError("injected evidence write failure")
            return atomic(path, value)
        with patch.object(m, "atomic_json", side_effect=fail_evidence):
            with self.assertRaises(OSError):
                self.backup.upload()
        self.assertFalse(self.runner.mounts)
        self.assertTrue(self.runner.snapshots)
        self.backup.upload()
        self.assertTrue((self.backup.state / "last-success.json").exists())
        self.assertEqual(sum(a[0] == "borg" and a[3] == "create" for a in self.runner.calls), 1)

    def test_snapshot_manifest_and_dump_mismatch_prevent_borg(self):
        for corrupt in ("capture.json", "first.sql"):
            with self.subTest(corrupt=corrupt):
                self.backup.capture()
                path = self.base / "snapshot-data" / corrupt
                path.write_text("{}" if corrupt.endswith("json") else "corrupted dump")
                with self.assertRaises(m.BackupError):
                    self.backup.upload()
                self.assertFalse(any(a[0] == "borg" for a in self.runner.calls))

    def test_low_space_releases_only_owned_snapshots(self):
        self.backup.capture()
        self.runner.snapshots.add("rpool/safe/persist@unrelated")
        self.runner.free = 9
        self.backup.watchdog()
        self.assertEqual(self.runner.snapshots, {"rpool/safe/persist@unrelated"})
        self.assertFalse(self.backup.load()["captureComplete"])

    def test_foreign_snapshot_owner_is_never_destroyed(self):
        self.backup.capture()
        snapshot = next(iter(self.runner.snapshots))
        self.runner.owners[snapshot] = "foreign"
        with self.assertRaisesRegex(m.BackupError, "ownership"):
            self.backup.discard(self.backup.load())
        self.assertIn(snapshot, self.runner.snapshots)

    def test_recovery_replay_after_abrupt_exit(self):
        run = self.backup.new_run()
        self.backup.save(run)
        self.backup.quiesce(run)
        self.backup.deadline = None  # Coordinator has disappeared.
        self.backup.external_recover()
        self.assert_resumed()
        self.assertEqual(self.backup.load()["phase"], "failed")
        count = len(self.runner.calls)
        self.backup.external_recover()
        self.assertFalse(any(a[:2] == ["systemctl", "start"] for a in self.runner.calls[count:]))

    def test_boot_recovery_marks_interrupted_capture_failed(self):
        run = self.backup.new_run()
        self.backup.save(run)
        self.backup.quiesce(run)
        self.backup.deadline = None
        self.backup.boot_recover()
        self.assert_resumed()
        self.assertEqual(self.backup.load()["phase"], "failed")
        self.assertFalse(self.backup.load()["captureComplete"])

    def test_recovery_continues_when_ledger_write_fails(self):
        run = self.backup.new_run()
        self.backup.save(run)
        self.backup.quiesce(run)
        self.backup.deadline = None
        with patch.object(self.backup, "save", side_effect=OSError("no space")):
            with self.assertRaises(OSError):
                self.backup.recover()
        self.assertEqual(self.runner.states["app.service"], "active")
        self.assertEqual(self.runner.states["cron.timer"], "active")
        self.assertFalse((self.backup.runtime / "maintenance").exists())

    def test_independent_watchdog_ends_maintenance_at_deadline(self):
        run = self.backup.new_run()
        run.update(maintenanceStarted=time.time() - 601, maintenanceMonotonic=time.monotonic() - 601, phase="resuming")
        self.backup.save(run)
        self.backup.flag("maintenance", True)
        self.backup.flag("quiescing", True)
        self.backup.watchdog()
        self.assertFalse((self.backup.runtime / "maintenance").exists())
        self.assertFalse((self.backup.runtime / "quiescing").exists())
        self.assertIn(["systemctl", "stop", "--no-block", "apollo-backup.service"], self.runner.calls)

    def test_postgresql_timeout_uses_capture_budget_and_remaining_time(self):
        run = self.backup.new_run()
        self.backup.save(run)
        self.backup.quiesce(run)
        self.assertEqual(self.backup.deadline - run["maintenanceMonotonic"], 475)
        with patch.object(self.runner, "run", return_value="") as command:
            self.backup.deadline = None
            self.backup.pg("psql")
            self.assertEqual(command.call_args.kwargs["timeout"], 475)
            self.backup.deadline = 1120
            with patch.object(m.time, "monotonic", return_value=1000):
                self.backup.pg("psql")
            self.assertEqual(command.call_args.kwargs["timeout"], 120)

    def test_watchdog_uses_new_capture_and_maintenance_boundaries(self):
        for phase, elapsed, stop, cleared in (
            ("dumping", 175, False, False),
            ("dumping", 300, False, False),
            ("dumping", 474, False, False),
            ("dumping", 475, True, False),
            ("resuming", 300, False, False),
            ("resuming", 599, False, False),
            ("resuming", 600, True, True),
        ):
            with self.subTest(phase=phase, elapsed=elapsed):
                run = self.backup.new_run()
                run.update(phase=phase, maintenanceStarted=time.time(), maintenanceMonotonic=1000)
                self.backup.save(run)
                self.backup.flag("maintenance", True)
                self.backup.flag("quiescing", True)
                self.runner.calls.clear()
                with patch.object(m.time, "monotonic", return_value=1000 + elapsed):
                    self.backup.watchdog()
                self.assertEqual(["systemctl", "stop", "--no-block", "apollo-backup.service"] in self.runner.calls, stop)
                self.assertEqual((self.backup.runtime / "maintenance").exists(), not cleared)
                self.assertEqual((self.backup.runtime / "quiescing").exists(), not cleared)
                if stop:
                    limit = 600 if phase == "resuming" else 475
                    self.assertTrue((self.backup.runtime / f"deadline-{run['id']}-{limit}").exists())

    def test_recovery_after_old_limit_is_still_within_new_budget(self):
        run = self.backup.new_run()
        self.backup.save(run)
        self.backup.quiesce(run)
        self.backup.deadline = None
        run = self.backup.load()
        run.update(maintenanceMonotonic=time.monotonic() - 500, captureComplete=True)
        self.backup.save(run)
        self.backup.recover()
        self.assert_resumed()
        self.assertTrue(self.backup.load()["captureComplete"])
        self.assertNotIn("recoveryError", self.backup.load())

    def test_supervised_timeout_check_uses_new_budget_and_marker(self):
        config_path = self.base / "config.json"
        config_path.write_text(json.dumps(self.c))
        argv = ["backup-verification.py", str(config_path), str(SCRIPT), "run", "timeout"]
        helper_spec = importlib.util.spec_from_file_location("verification", SCRIPT.with_name("backup-verification.py"))
        helper = importlib.util.module_from_spec(helper_spec)
        with patch.object(sys, "argv", argv):
            helper_spec.loader.exec_module(helper)
        run = self.backup.new_run()
        run.update(captureUnit="apollo-backup-test@timeout.service", resumed=True, maintenanceSeconds=500)
        (self.backup.runtime / f"deadline-{run['id']}-475").touch()
        with patch.object(sys, "argv", argv), \
             patch.object(helper.os, "geteuid", return_value=0), \
             patch.object(helper, "Verification", return_value=self.backup), \
             patch.object(self.backup, "guard", create=True), \
             patch.object(self.backup, "load", return_value=run) as load, \
             patch.object(self.backup, "call", return_value="") as command, \
             patch("builtins.print"):
            load.side_effect = [None, run, run]
            helper.main()
        command.assert_any_call("systemctl", "start", "apollo-backup-test@timeout.service", timeout=640)

    def test_new_capture_replaces_previous_set(self):
        self.backup.capture()
        old = set(self.runner.snapshots)
        self.backup.capture()
        self.assertEqual(len(self.runner.snapshots), 2)
        self.assertFalse(old & self.runner.snapshots)

    def test_export_file_permissions(self):
        self.backup.capture()
        directory = Path(self.c["dumpDirectory"])
        for relative in self.backup.load()["manifest"]["files"]:
            self.assertEqual((directory / relative).stat().st_mode & 0o777, 0o600)

    def test_pending_recovery_can_finish_after_deadline(self):
        run = self.backup.new_run()
        self.backup.save(run)
        self.backup.quiesce(run)
        self.backup.deadline = None
        run = self.backup.load()
        run["maintenanceMonotonic"] = time.monotonic() - 601
        self.backup.save(run)
        self.runner.start_failures.add("app.service")
        self.backup.recover()
        self.assertEqual(self.backup.load()["restoreApplications"], ["app.service"])
        self.assertEqual(self.backup.load()["phase"], "resuming")
        self.assertFalse((self.backup.runtime / "maintenance").exists())
        self.runner.start_failures.clear()
        self.backup.external_recover()
        self.assert_resumed()
        self.assertFalse(self.backup.load()["captureComplete"])
        self.assertIn("recoveryError", self.backup.load())
        self.assertEqual(self.backup.load()["phase"], "failed")

    def test_unexpected_database_fails_before_pausing(self):
        original = self.runner.run
        def run(args, **kwargs):
            if "psql" in args:
                return original(args, **kwargs) + "\nundeclared-application"
            return original(args, **kwargs)
        with patch.object(self.runner, "run", side_effect=run):
            with self.assertRaisesRegex(m.BackupError, "inventory"):
                self.backup.capture()
        self.assertFalse(self.backup.ledger.exists())

    def test_unexpected_nested_mount_fails_before_pausing(self):
        original = self.runner.run
        def run(args, **kwargs):
            if args[0] == "findmnt" and "--submounts" in args:
                return "/persist\n/persist/unreviewed"
            return original(args, **kwargs)
        with patch.object(self.runner, "run", side_effect=run):
            with self.assertRaisesRegex(m.BackupError, "nested mounts"):
                self.backup.capture()
        self.assertFalse(self.backup.ledger.exists())

    def test_publication_failure_cannot_be_archived(self):
        self.backup.capture()
        with patch.object(m.os, "link", side_effect=OSError("rotation failed")):
            with self.assertRaises(m.BackupError):
                self.backup.capture()
        self.assert_resumed()
        self.assertFalse(self.backup.load()["captureComplete"])
        self.backup.upload()
        self.assertFalse(any(a[0] == "borg" for a in self.runner.calls))

    def test_rotation_retains_old_inodes_and_publishes_separate_files(self):
        self.backup.capture()
        directory = Path(self.c["dumpDirectory"])
        old_files = {}
        for relative in self.backup.load()["manifest"]["files"]:
            target = directory / relative
            content = ("old " + relative).encode()
            target.write_bytes(content)
            old_files[relative] = (target.stat(), content)
        self.backup.capture()
        for relative, (old, content) in old_files.items():
            target = directory / relative
            previous = target.with_name(target.stem + ".prev.sql")
            self.assertEqual(previous.stat().st_ino, old.st_ino)
            self.assertEqual(previous.read_bytes(), content)
            self.assertEqual(previous.stat().st_mode, old.st_mode)
            self.assertEqual((previous.stat().st_uid, previous.stat().st_gid), (old.st_uid, old.st_gid))
            self.assertNotEqual(target.stat().st_ino, previous.stat().st_ino)
            self.assertEqual(target.read_bytes(), b"private test export\n")
            self.assertEqual(previous.stat().st_nlink, 1)
        self.assertEqual(list(directory.glob(".capture-*")), [])

    def test_interrupted_rotation_preserves_exports_and_can_retry(self):
        directory = Path(self.c["dumpDirectory"])
        target, previous = directory / "first.sql", directory / "first.prev.sql"
        for boundary in ("before_previous", "after_previous", "after_current"):
            with self.subTest(boundary=boundary):
                self.backup.capture()
                target.write_bytes(b"old current")
                previous.write_bytes(b"older previous")
                original = m.os.replace

                def replace(source, destination):
                    destination = Path(destination)
                    if destination == previous and boundary == "before_previous":
                        raise OSError("interrupted rotation")
                    result = original(source, destination)
                    if ((destination == previous and boundary == "after_previous") or
                            (destination == target and boundary == "after_current")):
                        raise OSError("interrupted rotation")
                    return result

                with patch.object(m.os, "replace", side_effect=replace):
                    with self.assertRaisesRegex(m.BackupError, "interrupted rotation"):
                        self.backup.capture()
                self.assert_resumed()
                self.assertEqual(self.backup.load()["phase"], "failed")
                self.assertEqual(target.read_bytes(), b"private test export\n" if boundary == "after_current" else b"old current")
                self.assertEqual(previous.read_bytes(), b"older previous" if boundary == "before_previous" else b"old current")
                self.assertFalse(self.runner.snapshots)
                self.assertEqual(list(directory.glob(".capture-*")), [])
                self.backup.external_recover()
                self.backup.upload()
                self.assertFalse(any(a[0] == "borg" for a in self.runner.calls))
                retry_previous = target.read_bytes()
                self.backup.capture()
                self.assertEqual(previous.read_bytes(), retry_previous)
                self.assertEqual(previous.stat().st_nlink, 1)

    def test_publication_deadline_after_retaining_previous_aborts_before_replacement(self):
        self.backup.capture()
        directory = Path(self.c["dumpDirectory"])
        target = directory / "first.sql"
        target.write_bytes(b"old export")
        original = m.sync_directory

        def sync(path):
            original(path)
            if Path(path) == directory:
                self.backup.deadline = time.monotonic() - 1

        with patch.object(m, "sync_directory", side_effect=sync):
            with self.assertRaisesRegex(m.BackupError, "deadline reached during dump publication"):
                self.backup.capture()
        self.assert_resumed()
        self.assertEqual(target.read_bytes(), b"old export")
        self.assertEqual((directory / "first.prev.sql").read_bytes(), b"old export")
        self.assertFalse(self.runner.snapshots)
        messages = "\n".join(call.args[0] for call in self.backup.log.call_args_list)
        self.assertIn("first.sql: publication failed after", messages)

    def test_crash_cleanup_removes_staged_link_without_removing_current_export(self):
        run = self.backup.new_run()
        self.backup.save(run)
        self.backup.quiesce(run)
        self.backup.deadline = None
        self.backup.phase(run, "publishing")
        directory = Path(self.c["dumpDirectory"])
        target = directory / "first.sql"
        target.write_bytes(b"old export")
        stage = directory / (".capture-" + run["id"])
        temporary = stage / ".previous/first.sql"
        temporary.parent.mkdir(parents=True)
        os.link(target, temporary)
        (stage / "first.sql").write_bytes(b"unpublished new export")
        self.assertEqual(target.stat().st_nlink, 2)
        self.backup.external_recover()
        self.assert_resumed()
        self.assertFalse(stage.exists())
        self.assertEqual(target.read_bytes(), b"old export")
        self.assertEqual(target.stat().st_nlink, 1)

    def test_rotation_rejects_symlink_without_touching_referenced_file(self):
        outside = self.base / "unrelated"
        outside.write_bytes(b"unrelated data")
        target = Path(self.c["dumpDirectory"]) / "first.sql"
        target.symlink_to(outside)
        with self.assertRaisesRegex(m.BackupError, "not a regular file"):
            self.backup.capture()
        self.assert_resumed()
        self.assertTrue(target.is_symlink())
        self.assertEqual(outside.read_bytes(), b"unrelated data")
        self.assertFalse(self.runner.snapshots)

    def test_recorded_archive_reconciles_interrupted_publication(self):
        self.backup.capture()
        run = self.backup.load()
        self.runner.archives.add(self.c["borg"]["prefix"] + "-" + run["id"])
        self.backup.upload()
        self.assertFalse(any(a[0] == "borg" and a[3] == "create" for a in self.runner.calls))
        self.assertTrue(self.backup.load()["archiveCreated"])

    def test_runner_timeout_terminates_process_group(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            m.Runner().run(["/bin/sh", "-c", "sleep 20 & wait"], timeout=0.05)

    def test_failed_ledger_write_preserves_record_and_removes_temporary(self):
        m.atomic_json(self.backup.ledger, {"previous": "record"})
        with patch.object(m.os, "fsync", side_effect=OSError("no space")):
            with self.assertRaises(OSError):
                m.atomic_json(self.backup.ledger, {"new": "record"})
        self.assertEqual(json.loads(self.backup.ledger.read_text()), {"previous": "record"})
        self.assertEqual(list(self.backup.state.glob(".publish-*")), [])


if __name__ == "__main__":
    unittest.main()
