#!/usr/bin/env python3
"""Apollo backup state machine. No third-party Python dependencies.

The systemd units supply PATH/configuration. Only root may invoke operational
commands. Tests inject a Runner and temporary paths; no production fault flags
are read by capture/upload.
"""

import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from zoneinfo import ZoneInfo


class BackupError(RuntimeError):
    pass


class Busy(BackupError):
    pass


def boot_id():
    return Path("/proc/sys/kernel/random/boot_id").read_text().strip()


class Runner:
    def run(self, args, *, timeout=30, stdout=None, env=None, cwd=None):
        # New process groups let a deadline terminate runuser AND its children.
        with subprocess.Popen(
            args, stdout=stdout if stdout is not None else subprocess.PIPE,
            stderr=None, text=stdout is None, env=env, cwd=cwd,
            start_new_session=True,
        ) as proc:
            try:
                output, _ = proc.communicate(timeout=timeout)
            except BaseException:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
                raise
            if proc.returncode:
                # Do not log SQL, credentials, or command output.
                raise BackupError(f"{args[0]} failed (exit {proc.returncode})")
            return output.strip() if output is not None else ""


def sync_directory(path):
    directory = os.open(path, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def atomic_json(path, value):
    path = Path(path)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, prefix=".publish-", delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        sync_directory(path.parent)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


@contextlib.contextmanager
def locked(path, *, blocking=False):
    # Never unlink a lock file: another process could still hold its inode.
    with open(path, "r+") as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        except BlockingIOError as exc:
            raise Busy("Another backup operation owns the lock") from exc
        yield


class Backup:
    def __init__(self, config, runner=None):
        self.c = config
        self.capture_work_seconds = config["captureSeconds"] - 5
        self.maintenance_seconds = config["captureSeconds"] + config["resumeSeconds"]
        self.r = runner or Runner()
        self.state = Path(config["state"])
        self.runtime = Path(config["runtime"])
        self.view = self.runtime / "private/source"
        self.ledger = self.state / "run.json"
        self.deadline = None
        self.capture_unit = "apollo-backup.service"
        self.testing = False

    def log(self, message):
        print(f"apollo-backup: {message}", flush=True)

    def call(self, *args, **kwargs):
        if self.deadline is not None:
            remaining = self.deadline - time.monotonic()
            if remaining <= 0:
                raise BackupError("Capture deadline reached")
            kwargs["timeout"] = min(kwargs.get("timeout", 30), remaining)
        return self.r.run(list(args), **kwargs)

    def load(self):
        if not self.ledger.exists():
            return None
        run = json.loads(self.ledger.read_text())
        if not re.fullmatch(r"\d{8}T\d{6}Z-[0-9a-f]{12}", run.get("id", "")):
            raise BackupError("Invalid run ledger; manual inspection required")
        if run.get("datasets") != self.c["datasets"]:
            raise BackupError("Ledger dataset layout differs; manual inspection required")
        if run.get("captureUnit") not in ["apollo-backup.service"] + [
            f"apollo-backup-test@{s}.service" for s in ("dump", "snapshot", "timeout", "kill", "retain", "concurrency")
        ]:
            raise BackupError("Unrecognized capture unit in ledger")
        return run

    def save(self, run):
        atomic_json(self.ledger, run)

    def phase(self, run, name):
        run["phase"] = name
        self.save(run)
        self.log(f"{run['id']}: {name}")

    def properties(self, unit):
        output = self.call(
            "systemctl", "show", unit,
            "--property=LoadState,ActiveState,SubState,MainPID,ControlPID,ControlGroup,Result",
        )
        return dict(line.split("=", 1) for line in output.splitlines() if "=" in line)

    @staticmethod
    def executing(properties):
        return (
            properties.get("ActiveState") in ("activating", "deactivating", "reloading")
            or properties.get("MainPID", "0") != "0"
            or properties.get("ControlPID", "0") != "0"
        )

    def populated(self, properties):
        group = properties.get("ControlGroup", "")
        if not group:
            return False
        if not group.startswith("/") or ".." in group.split("/"):
            raise BackupError("Unexpected cgroup path")
        events = Path("/sys/fs/cgroup") / group.lstrip("/") / "cgroup.events"
        if not events.exists():
            return False
        return "populated 1" in events.read_text()

    def pool_space(self):
        size, free = map(int, self.call("zpool", "list", "-Hp", "-o", "size,free", "rpool").split())
        return free * 100 >= size * self.c["minimumFreePercent"]

    def assert_no_migrations(self):
        for unit in self.c["migrations"]:
            properties = self.properties(unit)
            if self.executing(properties) or self.populated(properties):
                raise BackupError(f"Update/migration is executing: {unit}")
        pending = self.call("systemctl", "list-jobs", "--no-legend", "--no-pager")
        blocked = set(self.c["migrations"] + self.c["applications"] + self.c["jobs"])
        if any(set(line.split()) & blocked for line in pending.splitlines()):
            raise BackupError("A covered writer has a pending systemd job")

    def preflight(self):
        if not self.pool_space():
            raise BackupError("Less than 10% ZFS pool space is free")
        for relative, dataset in self.c["datasets"].items():
            mount = "/" + relative
            source = self.call("findmnt", "-n", "-o", "SOURCE", "--mountpoint", mount)
            if source != dataset:
                raise BackupError(f"Unexpected backing dataset at {mount}")
            datasets = self.call("zfs", "list", "-H", "-o", "name", "-r", "-t", "filesystem,volume", dataset)
            if datasets.splitlines() != [dataset]:
                raise BackupError(f"Unreviewed descendant datasets beneath {dataset}")
            mounts = self.call("findmnt", "-rn", "-o", "TARGET", "--submounts", "--mountpoint", mount)
            old = self.load()
            allowed = {mount}
            if old and old.get("snapshotsPlanned"):
                snapshot = dataset + "@" + self.snapshot_name(old)
                if snapshot in self.snapshot_inventory():
                    self.owned(snapshot, old)
                    allowed.add(mount + "/.zfs/snapshot/" + self.snapshot_name(old))
            if not set(mounts.splitlines()).issubset(allowed):
                raise BackupError(f"Unreviewed nested mounts beneath {mount}")
        for unit in ("postgresql.service", "postgresql-setup.service"):
            if self.properties(unit).get("ActiveState") != "active":
                raise BackupError(f"PostgreSQL provisioning is not ready: {unit}")
        expected = Path("/persist") / self.c["dumpDirectory"].lstrip("/")
        if not os.path.samefile(self.c["dumpDirectory"], expected):
            raise BackupError("Dump directory is not backed by /persist")
        actual = set(self.pg(
            "psql", "--no-password", "-X", "--dbname=postgres", "--tuples-only", "--no-align",
            "--command=SELECT datname FROM pg_database WHERE NOT datistemplate ORDER BY datname",
        ).splitlines()) - {"postgres"}
        selected = set(self.c["databases"])
        if actual - selected or selected - actual - {"postgres"}:
            raise BackupError("Live PostgreSQL database inventory differs from the selected dumps; review coverage")
        for unit in self.c["applications"] + self.c["jobs"] + self.c["migrations"] + self.c["timers"]:
            props = self.properties(unit)
            if props.get("LoadState") != "loaded":
                raise BackupError(f"Expected unit is not loaded: {unit}")
        self.assert_no_migrations()
        self.log(f"Maintenance budget: {self.maintenance_seconds} seconds total; "
                 f"capture cutoff {self.capture_work_seconds} seconds; "
                 f"resumption reserve {self.c['resumeSeconds']} seconds")
        self.log("Preflight passed; runtime service and dataset inventory matches")

    def new_run(self):
        now = dt.datetime.now(dt.timezone.utc)
        return {
            "id": now.strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:12],
            "capturedAt": now.isoformat(), "createdEpoch": time.time(),
            "borgTimestamp": now.strftime("%Y-%m-%dT%H:%M:%S"),
            "bootId": boot_id(),
            "datasets": self.c["datasets"], "phase": "prepared",
            "captureUnit": self.capture_unit, "testCapture": self.testing,
            "restoreApplications": [], "restoreTimers": [], "originalApplications": [], "originalTimers": [],
            "snapshotsPlanned": False, "captureComplete": False,
            "resumed": False, "archiveCreated": False, "retentionComplete": False,
            "consistencyExcluded": ["onlyoffice", "rabbitmq", "logs and other live host state"],
        }

    def flag(self, name, enabled):
        path = self.runtime / name
        if enabled:
            path.touch(mode=0o644, exist_ok=True)
        else:
            path.unlink(missing_ok=True)

    def quiesce(self, run):
        # Start timing before the first barrier, timer stop or application pause.
        run["maintenanceStarted"] = time.time()
        run["maintenanceMonotonic"] = time.monotonic()
        self.deadline = run["maintenanceMonotonic"] + self.capture_work_seconds
        # Reserve the last 5 capture seconds for systemd cgroup cancellation.
        self.phase(run, "quiescing")
        self.flag("quiescing", True)
        for unit in self.c["applications"]:
            props = self.properties(unit)
            if props.get("ActiveState") not in ("active", "inactive", "failed"):
                raise BackupError(f"Unstable service before capture: {unit}")
            if props.get("ActiveState") == "active":
                run["restoreApplications"].append(unit)
        for timer in self.c["timers"]:
            if self.properties(timer).get("ActiveState") == "active":
                run["restoreTimers"].append(timer)
        # Persist the complete restoration list before making stop requests.
        run["originalApplications"] = list(run["restoreApplications"])
        run["originalTimers"] = list(run["restoreTimers"])
        self.save(run)
        self.assert_no_migrations()
        self.call("systemctl", "stop", *self.c["timers"])
        while any(self.executing(p := self.properties(u)) or self.populated(p) for u in self.c["jobs"]):
            self.pause()
        self.flag("maintenance", True)
        if run["restoreApplications"]:
            self.call("systemctl", "stop", "--no-block", *run["restoreApplications"])
        while True:
            props = [self.properties(u) for u in self.c["applications"]]
            if all(p.get("ActiveState") in ("inactive", "failed") and not self.populated(p) for p in props):
                # A forced or failed shutdown is not a clean capture boundary.
                if any(self.properties(u).get("Result") not in (None, "success")
                       for u in run["restoreApplications"]):
                    raise BackupError("A covered application did not stop cleanly")
                break
            self.pause()
        self.assert_no_migrations()

    def pause(self):
        if self.deadline is not None and time.monotonic() >= self.deadline:
            raise BackupError("Capture deadline reached")
        time.sleep(0.2)

    def pg(self, *args, stdout=None):
        env = os.environ.copy()
        env.update(PGHOST="/run/postgresql", PGPORT=self.c["pgPort"], PGUSER="postgres")
        return self.call("runuser", "-u", "postgres", "--", *args, stdout=stdout, env=env,
                         timeout=self.capture_work_seconds)

    def digest(self, path):
        digest = hashlib.sha256()
        with open(path, "rb") as stream:
            while chunk := stream.read(1024 * 1024):
                digest.update(chunk)
                if self.deadline is not None and time.monotonic() >= self.deadline:
                    raise BackupError("Capture deadline reached during dump validation")
        return digest.hexdigest()

    @contextlib.contextmanager
    def timed_export_step(self, relative, step):
        started = time.monotonic()
        self.log(f"{relative}: {step} started")
        try:
            yield
        except BaseException:
            self.log(f"{relative}: {step} failed after {time.monotonic() - started:.3f} seconds")
            raise
        else:
            self.log(f"{relative}: {step} completed in {time.monotonic() - started:.3f} seconds")

    def dumps(self, run):
        self.phase(run, "dumping")
        directory = Path(self.c["dumpDirectory"])
        stage = directory / (".capture-" + run["id"])
        stage.mkdir(mode=0o700)
        postgres = pwd.getpwnam("postgres")
        os.chown(stage, postgres.pw_uid, postgres.pw_gid)
        # Keep custom-format restore support without spending the maintenance
        # window on pg_dump's default gzip compression. Borg compresses later.
        exports = [(db + ".sql", ["pg_dump", "--no-password", "--format=custom", "--compress=0", "--dbname=" + db])
                   for db in self.c["databases"]]
        exports.append(("globals/globals.sql", ["pg_dumpall", "--globals-only", "--no-password"]))
        records = {}
        try:
            for relative, command in exports:
                target = stage / relative
                target.parent.mkdir(mode=0o700, exist_ok=True)
                os.chown(target.parent, postgres.pw_uid, postgres.pw_gid)
                # Root opens the output privately; only the configured PostgreSQL
                # client gets the descriptor. No password hashes reach the journal.
                with self.timed_export_step(relative, "dump and sync"):
                    with open(target, "xb") as output:
                        os.fchmod(output.fileno(), 0o600)
                        os.fchown(output.fileno(), postgres.pw_uid, postgres.pw_gid)
                        self.pg(*command, stdout=output)
                        output.flush()
                        os.fsync(output.fileno())
                self.log(f"{relative}: {target.stat().st_size} bytes")
                with self.timed_export_step(relative, "validation and checksum"):
                    if not target.stat().st_size:
                        raise BackupError(f"Empty export: {relative}")
                    if relative != "globals/globals.sql":
                        self.call("pg_restore", "--list", str(target), stdout=subprocess.DEVNULL)
                    records[relative] = {"size": target.stat().st_size, "sha256": self.digest(target)}
            # Publish only after every new output has passed validation.
            self.phase(run, "publishing")
            for relative, _ in exports:
                with self.timed_export_step(relative, "publication"):
                    self.publish_export(directory, stage, relative)
            manifest = {
                "runId": run["id"], "capturedAt": run["capturedAt"],
                "databases": self.c["databases"], "files": records,
                "consistencyExcluded": run["consistencyExcluded"],
            }
            with self.timed_export_step("capture.json", "publication"):
                self.publication_deadline()
                atomic_json(directory / "capture.json", manifest)
                run["manifest"] = manifest
                self.save(run)
                self.publication_deadline()
        finally:
            shutil.rmtree(stage, ignore_errors=True)

    def publication_deadline(self):
        if self.deadline is not None and time.monotonic() >= self.deadline:
            raise BackupError("Capture deadline reached during dump publication")

    def publish_export(self, directory, stage, relative):
        self.publication_deadline()
        target = directory / relative
        try:
            old = target.lstat()
        except FileNotFoundError:
            old = None
        if old is not None:
            if not stat.S_ISREG(old.st_mode):
                raise BackupError(f"Previous export is not a regular file: {relative}")
            previous = target.with_name(target.stem + ".prev.sql")
            temporary = stage / ".previous" / relative
            temporary.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            # Published dumps must never be overwritten in place. All managed
            # exporters write separate files and rename them, so the old inode
            # can be retained without copying its potentially large contents.
            # Keep temporary links in this run's stage for existing crash cleanup.
            os.link(target, temporary, follow_symlinks=False)
            self.publication_deadline()
            os.replace(temporary, previous)
            # Make the retained name durable BEFORE replacing the current name.
            sync_directory(target.parent)
        self.publication_deadline()
        os.replace(stage / relative, target)
        sync_directory(target.parent)
        self.publication_deadline()

    def snapshot_name(self, run):
        return "apollo-backup-" + run["id"]

    def snapshots(self, run):
        return [dataset + "@" + self.snapshot_name(run) for dataset in self.c["datasets"].values()]

    def take_snapshots(self, run):
        self.phase(run, "snapshotting")
        run["snapshotsPlanned"] = True
        self.save(run)  # Write-ahead intent permits cleanup after SIGKILL.
        self.call("zfs", "snapshot", "-o", "org.apollo:backup=" + run["id"], *self.snapshots(run))
        run["captureComplete"] = True
        self.save(run)

    def snapshot_inventory(self):
        return set(self.call("zfs", "list", "-H", "-o", "name", "-t", "snapshot", "-r", "rpool/safe").splitlines())

    def owned(self, snapshot, run):
        owner = self.call("zfs", "get", "-H", "-o", "value", "org.apollo:backup", snapshot)
        if snapshot not in self.snapshots(run) or owner != run["id"]:
            raise BackupError("Refusing to act on a snapshot without exact T04 ownership")

    def unmount(self, run=None):
        run = run or self.load()
        for relative, dataset in reversed(list(self.c["datasets"].items())):
            target = self.view / relative
            if not target.exists() or not os.path.ismount(target):
                continue
            source = self.call("findmnt", "-n", "-o", "SOURCE", "--mountpoint", str(target))
            if not run or source != dataset + "@" + self.snapshot_name(run):
                raise BackupError("Refusing to unmount an unrecognized snapshot view")
            self.call("umount", str(target), timeout=2)

    def discard(self, run):
        self.unmount(run)
        inventory = self.snapshot_inventory() if run.get("snapshotsPlanned") else set()
        for snapshot in self.snapshots(run):
            if snapshot in inventory:
                self.owned(snapshot, run)
                self.call("zfs", "destroy", snapshot)
        run["snapshotsPlanned"] = False
        run["captureComplete"] = False
        self.save(run)
        # A killed exporter may leave this run's private staging directory.
        stage = Path(self.c["dumpDirectory"]) / (".capture-" + run["id"])
        if stage.exists():
            shutil.rmtree(stage)

    def capture(self):
        # A previous day's hung upload must not indefinitely block the next night.
        old = self.load()
        if old and dt.datetime.fromtimestamp(old["createdEpoch"], ZoneInfo("Europe/Vienna")).date() < dt.datetime.now(ZoneInfo("Europe/Vienna")).date():
            self.call("systemctl", "stop", "apollo-backup-upload.service", timeout=20)
        with locked(self.runtime / "operation.lock"):
            old = self.load()
            if old and (old.get("restoreApplications") or old.get("restoreTimers")):
                raise BackupError("An earlier maintenance recovery is unfinished")
            self.preflight()
            if old:
                self.discard(old)
                atomic_json(self.state / "last-run.json", old)
            run = self.new_run()
            self.save(run)
            error = None
            try:
                self.quiesce(run)
                self.dumps(run)
                self.take_snapshots(run)
            except BaseException as exc:
                error = exc
                run["error"] = str(exc)
                run["captureComplete"] = False
                self.save(run)
            finally:
                self.deadline = None
                self.recover()
            run = self.load()
            if error or not run.get("resumed") or not run.get("captureComplete"):
                self.discard(run)
                if run.get("resumed"):
                    self.phase(run, "failed")
                raise BackupError(str(error or "Application resumption failed"))
            self.phase(run, "ready")

    def recover(self, boot=False):
        with locked(self.runtime / "recovery.lock", blocking=True):
            run = self.load()
            if not run:
                self.flag("quiescing", False)
                self.flag("maintenance", False)
                return
            if not run.get("maintenanceStarted"):
                return
            if run.get("resumed") and not (run.get("restoreApplications") or run.get("restoreTimers")):
                self.flag("quiescing", False)
                self.flag("maintenance", False)
                return
            # Availability must not depend on a writable pool. The restoration
            # list was durably recorded BEFORE any stop request.
            try:
                self.phase(run, "resuming")
            except OSError as exc:
                self.log(f"Cannot persist recovery phase; resuming anyway: {exc}")
            self.flag("quiescing", False)
            deadline = run["maintenanceMonotonic"] + self.maintenance_seconds
            # On a new boot the old wall-clock budget is already lost; do not
            # let a saved deadline keep normally enabled services held back.
            if boot:
                deadline = time.monotonic() + self.c["resumeSeconds"]
            errors = []
            try:
                if run["restoreApplications"]:
                    self.call("systemctl", "start", "--no-block", *run["restoreApplications"])
                while run["restoreApplications"]:
                    remaining = []
                    for unit in run["restoreApplications"]:
                        props = self.properties(unit)
                        if props.get("ActiveState") != "active" or not self.listening(unit):
                            remaining.append(unit)
                    run["restoreApplications"] = remaining
                    self.save(run)
                    if not remaining or time.monotonic() >= deadline:
                        break
                    if remaining:
                        time.sleep(0.2)
            except BaseException as exc:
                errors.append(str(exc))
            finally:
                # Never leave a synthetic outage behind when a real service fails.
                self.flag("maintenance", False)
                for timer in list(run["restoreTimers"]):
                    try:
                        self.call("systemctl", "start", timer, timeout=5)
                        run["restoreTimers"].remove(timer)
                        self.save(run)
                    except Exception as exc:
                        errors.append(str(exc))
                elapsed = (time.time() - run["maintenanceStarted"] if boot else
                           time.monotonic() - run["maintenanceMonotonic"])
                run["maintenanceSeconds"] = round(elapsed, 3)
                run["resumed"] = not (run["restoreApplications"] or run["restoreTimers"] or errors)
                if run["maintenanceSeconds"] > self.maintenance_seconds or not run["resumed"]:
                    run["recoveryError"] = "; ".join(errors) or (
                        f"Resumption exceeded {self.maintenance_seconds} seconds or a service did not start")
                    run["captureComplete"] = False
                self.save(run)
                self.log(f"Resumption: {run['resumed']}; maintenance {run['maintenanceSeconds']} seconds")

    def listening(self, unit):
        address = self.c.get("listeners", {}).get(unit)
        if not address:
            return True  # Worker has no required public listener.
        try:
            if "socket" in address:
                with socket.socket(socket.AF_UNIX) as connection:
                    connection.settimeout(0.2)
                    connection.connect(address["socket"])
            else:
                with socket.create_connection((address["host"], int(address["port"])), timeout=0.2):
                    pass
            return True
        except OSError:
            return False

    def external_recover(self):
        # The recovery service is ordered AFTER the capture service's stop job.
        # Its lock also excludes upload/manual dump entrypoints during cleanup.
        with locked(self.runtime / "operation.lock"):
            run = self.load()
            phase = run.get("phase") if run else None
            self.recover(boot=bool(run and run.get("bootId") != boot_id()))
            if run and phase not in ("ready", "uploading", "complete"):
                run = self.load()
                self.discard(run)
                if run.get("resumed"):
                    self.phase(run, "failed")

    def boot_recover(self):
        with locked(self.runtime / "operation.lock"):
            run = self.load()
            self.recover(boot=True)
            if run:
                run = self.load()
                if not run.get("resumed") or run.get("phase") not in ("ready", "uploading", "complete"):
                    self.discard(run)
                    if run.get("resumed"):
                        self.phase(run, "failed")
                # No automatic boot-time upload or new maintenance window.

    def mount_capture(self, run):
        if not run.get("captureComplete") or not run.get("resumed"):
            raise BackupError("No validated, resumed capture is available")
        for relative, dataset in self.c["datasets"].items():
            snapshot = dataset + "@" + self.snapshot_name(run)
            self.owned(snapshot, run)
            source = Path("/" + relative) / ".zfs/snapshot" / self.snapshot_name(run)
            target = self.view / relative
            target.mkdir(parents=True, mode=0o700, exist_ok=True)
            if os.path.ismount(target):
                raise BackupError("Snapshot view is unexpectedly mounted")
            self.call("mount", "--bind", str(source), str(target))
            self.call("mount", "-o", "remount,bind,ro", str(target))
            actual = self.call("findmnt", "-n", "-o", "SOURCE", "--mountpoint", str(target))
            if actual != snapshot:
                raise BackupError("Snapshot view resolved to the wrong source")
        directory = self.view / "persist" / self.c["dumpDirectory"].lstrip("/")
        self.verify_manifest(directory, run)

    def verify_manifest(self, directory, run):
        manifest = json.loads((directory / "capture.json").read_text())
        if manifest != run.get("manifest") or manifest.get("runId") != run["id"]:
            raise BackupError("Snapshot manifest does not identify this capture")
        for relative, record in manifest["files"].items():
            path = directory / relative
            if path.stat().st_size != record["size"] or self.digest(path) != record["sha256"]:
                raise BackupError(f"Snapshot dump differs from validated capture: {relative}")
            if path.stat().st_mode & 0o777 != 0o600:
                raise BackupError(f"Dump permissions differ from 0600: {relative}")

    def borg(self, *args, **kwargs):
        return self.call("borg", "--lock-wait", "5", *args, timeout=86400, **kwargs)

    def record_archive_success(self, run):
        # This evidence survives replacement of run.json. Test archives and
        # incomplete uploads must never reset the production freshness clock.
        if self.testing or run.get("testCapture") or not run.get("archiveCreated"):
            return
        path = self.state / "last-success.json"
        old = json.loads(path.read_text()) if path.exists() else None
        if old and old["capturedEpoch"] >= run["createdEpoch"]:
            return
        atomic_json(path, {
            "version": 1, "runId": run["id"], "archive": run["archive"],
            "capturedEpoch": run["createdEpoch"], "uploadedEpoch": time.time(),
            "production": True,
        })

    def upload(self):
        # No run is a normal timer no-op; a failed capture is never an upload source.
        with locked(self.runtime / "operation.lock"):
            run = self.load()
            if not run or not run.get("captureComplete") or run.get("retentionComplete"):
                self.log("No pending capture to upload")
                return
            if run.get("testCapture") and not self.testing:
                self.log("Test captures require the supervised verification uploader")
                return
            if not self.pool_space():
                self.discard(run)
                raise BackupError("Retained capture discarded below 10% free space")
            # The retry timer also ticks at 03:00; leave that slot to capture.
            local = dt.datetime.now(ZoneInfo("Europe/Vienna"))
            captured = dt.datetime.fromtimestamp(run["createdEpoch"], ZoneInfo("Europe/Vienna"))
            if local.hour == 3 and captured.date() < local.date():
                return
            name = self.c["borg"]["prefix"] + "-" + run["id"]
            run["archive"] = name
            self.phase(run, "uploading")
            try:
                self.unmount(run)  # Finish cleanup interrupted during a prior attempt.
                self.mount_capture(run)
                if not run.get("archiveCreated"):
                    # Reconcile a crash between successful rename and ledger fsync.
                    archives = self.borg("list", "--short").splitlines()
                    if name not in archives:
                        # Incomplete attempts must not displace successful archives
                        # in the existing retention prefix. Reuse one pending name.
                        attempt = "apollo-incomplete-" + self.c["borg"]["prefix"] + ".failed"
                        for prior in archives:
                            if prior == attempt or re.fullmatch(re.escape(attempt) + r"\.checkpoint(?:\.\d+)?", prior):
                                self.borg("delete", "::" + prior)
                        options = ["create", "--compression", self.c["borg"]["compression"],
                                   "--timestamp", run["borgTimestamp"], "--comment", "Apollo capture " + run["id"]]
                        for pattern in self.c["borg"]["exclude"]:
                            options.extend(["--exclude", pattern])
                        self.borg(*options, "::" + attempt, "persist", "var/log", cwd=self.view)
                        self.borg("rename", "::" + attempt, name)
                    run["archiveCreated"] = True
                    self.save(run)
                self.record_archive_success(run)
                options = ["prune", "--glob-archives", self.c["borg"]["prefix"] + "-*"]
                for period, number in self.c["borg"]["keep"].items():
                    options.extend(["--keep-" + period, str(number)])
                self.borg(*options)
                self.borg("compact")
                run["retentionComplete"] = True
                self.save(run)
            except BaseException as exc:
                run["uploadError"] = str(exc)
                self.save(run)
                raise
            finally:
                self.unmount(run)
            self.discard(run)
            self.phase(run, "complete")

    def watchdog(self):
        run = self.load()
        if not run:
            return
        if run.get("maintenanceStarted") and not run.get("resumed"):
            elapsed = time.monotonic() - run.get("maintenanceMonotonic", 0)
            if run.get("bootId") != boot_id():
                elapsed = 0  # Recovery handles old monotonic timestamps separately.
            limit = self.maintenance_seconds if run.get("phase") == "resuming" else self.capture_work_seconds
            if elapsed >= limit:
                if elapsed >= self.maintenance_seconds:
                    self.flag("quiescing", False)
                    self.flag("maintenance", False)
                marker = self.runtime / ("deadline-" + run["id"] + "-" + str(limit))
                if not marker.exists():
                    marker.touch(mode=0o600)
                    self.call("systemctl", "stop", "--no-block", run["captureUnit"])
                    self.call("systemctl", "start", "--no-block", "apollo-backup-recover.service")
        # Capacity needs checking only once a minute, even though the maintenance
        # watchdog ticks every second. Timestamp is runtime-only and nonsecret.
        checked = self.runtime / "space-checked"
        if run.get("snapshotsPlanned") and (not checked.exists() or time.time() - checked.stat().st_mtime >= 60):
            checked.touch(mode=0o600)
            if not self.pool_space():
                self.call("systemctl", "stop", "apollo-backup-upload.service", run["captureUnit"], timeout=20)
                with locked(self.runtime / "operation.lock"):
                    run = self.load()
                    self.discard(run)
                    run["error"] = "Capture discarded below 10% free pool capacity"
                    self.save(run)
                    self.log(run["error"])
        if run.get("restoreApplications") or run.get("restoreTimers"):
            props = self.properties(run["captureUnit"])
            if props.get("ActiveState") in ("inactive", "failed"):
                self.call("systemctl", "start", "--no-block", "apollo-backup-recover.service")


def main():
    if len(sys.argv) < 3:
        raise BackupError("Usage: apollo-backup CONFIG COMMAND")
    with open(sys.argv[1]) as stream:
        backup = Backup(json.load(stream))
    command = sys.argv[2]
    if os.geteuid() != 0:
        raise BackupError("Run this command as root")
    if command == "status":
        print(json.dumps(backup.load() or {"phase": "no recorded run"}, indent=2))
        return
    if command == "archive-name":
        run = backup.load()
        if not run or not run.get("archiveCreated"):
            raise BackupError("No completed archive is recorded for the current capture")
        print(run["archive"])
        return
    if command == "check-resumed":
        run = backup.load()
        if any((backup.runtime / name).exists() for name in ("quiescing", "maintenance")) or (
            run and (run.get("restoreApplications") or run.get("restoreTimers") or
                     (run.get("maintenanceStarted") and not run.get("resumed")))
        ):
            raise BackupError("Maintenance recovery is unfinished; inspect apollo-backup-status")
        backup.log("No pending maintenance restoration or backup barriers")
        return
    if command == "verify-extracted" and len(sys.argv) == 4:
        run = backup.load()
        if not run or not run.get("archiveCreated"):
            raise BackupError("No completed archive is recorded")
        backup.verify_manifest(Path(sys.argv[3]) / "persist/var/backup/postgresql", run)
        backup.log("Extracted dump set matches the recorded archive manifest and private modes")
        return
    commands = {
        "preflight": backup.preflight, "capture": backup.capture,
        "recover": backup.external_recover, "boot-recover": backup.boot_recover,
        "upload": backup.upload, "watchdog": backup.watchdog,
        "unmount": lambda: unmount_locked(backup),
    }
    if command not in commands:
        raise BackupError("Unknown backup command")
    if command != "preflight" and not os.environ.get("INVOCATION_ID"):
        raise BackupError("Start the corresponding systemd service; operational commands require its cleanup supervision")
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(BackupError("Cancelled by SIGTERM")))
    commands[command]()


def unmount_locked(backup):
    try:
        with locked(backup.runtime / "operation.lock"):
            backup.unmount()
    except Busy:
        backup.log("View cleanup deferred to the operation owning the lock")


if __name__ == "__main__":
    try:
        main()
    except (BackupError, OSError, subprocess.TimeoutExpired) as exc:
        print(f"apollo-backup: FAILED: {exc}", file=sys.stderr)
        sys.exit(75 if isinstance(exc, Busy) else 1)
