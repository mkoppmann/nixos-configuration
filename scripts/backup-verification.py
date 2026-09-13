#!/usr/bin/env python3
"""Explicit, supervised live failure tests; never used by production timers."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import sys
import time

spec = importlib.util.spec_from_file_location("backup", sys.argv[2])
backup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backup)
SCENARIOS = ("dump", "snapshot", "timeout", "kill", "retain", "upload", "low-space", "concurrency")


class Verification(backup.Backup):
    def __init__(self, config, scenario):
        super().__init__(config)
        if scenario not in SCENARIOS:
            raise backup.BackupError("Unknown verification scenario")
        self.scenario = scenario
        self.capture_unit = f"apollo-backup-test@{scenario}.service"
        self.testing = True

    def guard(self):
        for timer in ("apollo-backup.timer", "apollo-backup-upload.timer"):
            if self.properties(timer).get("ActiveState") != "inactive":
                raise backup.BackupError("Stop capture/retry timers before supervised tests")
        for unit in ("apollo-backup.service", "apollo-backup-upload.service", "apollo-backup-recover.service"):
            if self.executing(self.properties(unit)):
                raise backup.BackupError(f"Wait for {unit} to finish before testing")
        run = self.load()
        if run and run.get("captureComplete") and not run.get("testCapture"):
            raise backup.BackupError("Finish uploading the production capture before replacing it with a test")
        if self.scenario in ("upload", "low-space") and not (run and run.get("testCapture") and run.get("captureComplete")):
            raise backup.BackupError("First run the 'retain' scenario to produce a disposable test capture")

    def dumps(self, run):
        self.phase(run, "dumping")
        if self.scenario == "dump":
            raise backup.BackupError("TEST: simulated dump failure")
        if self.scenario == "kill":
            os.kill(os.getpid(), signal.SIGKILL)
        if self.scenario == "timeout":
            self.log("TEST: waiting for the independent maintenance watchdog")
            while True:
                time.sleep(1)
        if self.scenario == "concurrency":
            try:
                self.call("systemctl", "start", "apollo-backup-upload.service", timeout=10)
            except backup.BackupError:
                properties = self.call("systemctl", "show", "apollo-backup-upload.service", "--property=ExecMainStatus", "--value")
                if properties != "75":
                    raise backup.BackupError("TEST: competing upload failed for a reason other than locking")
                raise backup.BackupError("TEST: competing upload correctly rejected by shared lock")
            raise backup.BackupError("TEST: ERROR: competing uploader unexpectedly succeeded")
        return super().dumps(run)

    def take_snapshots(self, run):
        if self.scenario == "snapshot":
            raise backup.BackupError("TEST: simulated ZFS snapshot failure")
        return super().take_snapshots(run)

    def borg(self, *args, **kwargs):
        if self.scenario == "upload":
            raise backup.BackupError("TEST: simulated remote upload failure; no remote command was issued")
        return super().borg(*args, **kwargs)

    def pool_space(self):
        return False if self.scenario == "low-space" else super().pool_space()

    def worker(self):
        self.guard()
        if self.scenario == "upload":
            self.upload()
        elif self.scenario == "low-space":
            (self.runtime / "space-checked").unlink(missing_ok=True)
            self.watchdog()
        else:
            self.capture()


def main():
    if os.geteuid() != 0:
        raise backup.BackupError("Run supervised verification as root")
    config = json.loads(Path(sys.argv[1]).read_text())
    args = sys.argv[3:]
    if len(args) != 2 or args[0] not in ("run", "worker") or args[1] not in SCENARIOS:
        raise backup.BackupError("Usage: apollo-backup-verify run " + "|".join(SCENARIOS))
    mode, scenario = args
    test = Verification(config, scenario)
    if mode == "worker":
        if not os.environ.get("INVOCATION_ID"):
            raise backup.BackupError("Workers must be invoked through their systemd unit")
        signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(backup.BackupError("TEST: cancelled by watchdog")))
        test.worker()
        return
    test.guard()
    before = test.load()
    before_id = before["id"] if before else None
    print(f"Starting supervised {scenario} test. Covered applications may pause for up to "
          f"{test.maintenance_seconds} seconds.", flush=True)
    unit = f"apollo-backup-test@{scenario}.service"
    try:
        test.call("systemctl", "start", unit, timeout=test.maintenance_seconds + 40)
    except backup.BackupError:
        if scenario not in ("dump", "snapshot", "timeout", "kill", "upload", "concurrency"):
            raise
    # Join the independent cleanup job before reporting a pass or allowing the
    # next test. A resumed ledger can precede completion of snapshot cleanup.
    test.call("systemctl", "start", "apollo-backup-recover.service", timeout=config["resumeSeconds"] + 10)
    deadline = time.monotonic() + config["resumeSeconds"] + 10
    while time.monotonic() < deadline:
        run = test.load()
        if run and run.get("resumed") and not (test.runtime / "maintenance").exists():
            break
        time.sleep(1)
    run = test.load()
    if scenario not in ("upload", "low-space") and (not run or run["id"] == before_id or run["captureUnit"] != unit):
        raise backup.BackupError("TEST FAILED: no new run was started by the requested scenario")
    if not run or not run.get("resumed") or run.get("maintenanceSeconds", test.maintenance_seconds + 1) > test.maintenance_seconds:
        raise backup.BackupError(f"TEST FAILED: applications did not resume within {test.maintenance_seconds} seconds; "
                                "follow recovery instructions")
    if scenario in ("retain", "upload"):
        if not run.get("captureComplete"):
            raise backup.BackupError("TEST FAILED: expected one retained test capture")
    elif run.get("captureComplete") or run.get("snapshotsPlanned"):
        raise backup.BackupError("TEST FAILED: invalid capture or snapshots remained after cleanup")
    if scenario == "concurrency" and "correctly rejected" not in run.get("error", ""):
        raise backup.BackupError("TEST FAILED: lock rejection not established")
    if scenario in ("dump", "snapshot") and f"TEST: simulated {'dump' if scenario == 'dump' else 'ZFS snapshot'} failure" not in run.get("error", ""):
        raise backup.BackupError("TEST FAILED: capture failed before reaching the requested fault")
    if scenario == "upload" and "TEST: simulated remote upload failure" not in run.get("uploadError", ""):
        raise backup.BackupError("TEST FAILED: upload did not reach the requested fault")
    if scenario == "timeout" and not (test.runtime / ("deadline-" + run["id"] + "-" + str(test.capture_work_seconds))).exists():
        raise backup.BackupError("TEST FAILED: independent watchdog did not fire")
    if scenario == "kill" and test.call("systemctl", "show", unit, "--property=ExecMainStatus", "--value") != "9":
        raise backup.BackupError("TEST FAILED: coordinator SIGKILL was not observed")
    for unit in run.get("originalApplications", []):
        if test.properties(unit).get("ActiveState") != "active" or not test.listening(unit):
            raise backup.BackupError(f"TEST FAILED: {unit} is not ready")
    print(f"PASS: {scenario}; resumption {run['maintenanceSeconds']} seconds. Inspect the journal and application behavior too.")


if __name__ == "__main__":
    try:
        main()
    except (backup.BackupError, OSError) as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
