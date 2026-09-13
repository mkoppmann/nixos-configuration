"""Exercise the production globals script without Nix or a PostgreSQL server."""

import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "modules/postgresql-globals-backup.sh"


class GlobalsBackupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="apollo-t02-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.backups = self.directory / "backups with spaces"
        self.backups.mkdir(mode=0o700)
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        self.stub(
            "pg_dumpall",
            """#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == "--globals-only --no-password" ]]
[[ "$PGHOST" == /run/postgresql && "$PGPORT" == 5432 && "$PGUSER" == postgres ]]
case "$TEST_DUMP_MODE" in
  success) printf '%s\\n' "$TEST_DUMP_CONTENT" ;;
  failure) printf 'partial SQL\\n'; exit 42 ;;
  empty) exit 0 ;;
  terminate) kill -TERM "$PPID" ;;
  *) exit 99 ;;
esac
""",
        )
        self.environment = dict(
            os.environ,
            PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            PG_BACKUP_DIR=str(self.backups),
            PGHOST="/run/postgresql",
            PGPORT="5432",
            PGUSER="postgres",
            TEST_DUMP_MODE="success",
            TEST_DUMP_CONTENT="synthetic globals version 1",
        )

    def stub(self, name, content):
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o700)

    def run_backup(self, mode="success", content="synthetic globals version 1"):
        environment = dict(
            self.environment, TEST_DUMP_MODE=mode, TEST_DUMP_CONTENT=content
        )
        return subprocess.run(
            ["bash", str(SCRIPT)],
            env=environment,
            capture_output=True,
            text=True,
            timeout=10,
        )

    def seed_versions(self):
        for name, content in [
            ("globals.sql", "last successful version\n"),
            ("globals.prev.sql", "previous successful version\n"),
        ]:
            path = self.backups / name
            path.write_text(content)
            path.chmod(0o600)

    def versions(self):
        return {
            path.name: path.read_text()
            for path in self.backups.iterdir()
            if path.name in {"globals.sql", "globals.prev.sql"}
        }

    def assert_no_temporary_files(self):
        self.assertEqual(list(self.backups.glob("*.in-progress.sql")), [])

    def test_first_success_and_rotation(self):
        result = self.run_backup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "")
        self.assertEqual(
            self.versions(), {"globals.sql": "synthetic globals version 1\n"}
        )
        result = self.run_backup(content="synthetic globals version 2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.versions(),
            {
                "globals.sql": "synthetic globals version 2\n",
                "globals.prev.sql": "synthetic globals version 1\n",
            },
        )
        for path in self.backups.iterdir():
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.backups.stat().st_mode), 0o700)
        self.assert_no_temporary_files()

    def test_failed_empty_and_terminated_exports_preserve_both_versions(self):
        self.seed_versions()
        before = self.versions()
        for mode, expected_code in [("failure", 42), ("empty", 1), ("terminate", 143)]:
            with self.subTest(mode=mode):
                result = self.run_backup(mode)
                self.assertEqual(result.returncode, expected_code, result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertNotIn("partial SQL", result.stderr)
                self.assertEqual(self.versions(), before)
                self.assert_no_temporary_files()

    def test_failed_first_export_publishes_nothing(self):
        result = self.run_backup("failure")
        self.assertEqual(result.returncode, 42)
        self.assertEqual(list(self.backups.iterdir()), [])

    def test_failed_previous_copy_preserves_both_versions(self):
        self.seed_versions()
        before = self.versions()
        self.stub("cp", '#!/usr/bin/env bash\nprintf partial > "$3"\nexit 1\n')
        result = self.run_backup()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.versions(), before)
        self.assert_no_temporary_files()

    def test_failed_final_rename_preserves_current(self):
        self.seed_versions()
        self.stub(
            "mv",
            """#!/usr/bin/env bash
if [[ "$3" == globals.in-progress.sql ]]; then exit 1; fi
exec /bin/mv "$@"
""",
        )
        result = self.run_backup()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(
            self.versions()["globals.sql"], "last successful version\n"
        )
        self.assert_no_temporary_files()

    def test_stale_temporary_files_are_replaced_with_private_files(self):
        for name in ["globals.in-progress.sql", "globals.prev.in-progress.sql"]:
            path = self.backups / name
            path.write_text("incomplete previous attempt")
            path.chmod(0o644)
        result = self.run_backup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            stat.S_IMODE((self.backups / "globals.sql").stat().st_mode), 0o600
        )
        self.assert_no_temporary_files()

    def test_missing_directory_does_not_create_an_ephemeral_backup(self):
        self.environment["PG_BACKUP_DIR"] = str(self.directory / "missing")
        result = self.run_backup()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.directory / "missing").exists())


if __name__ == "__main__":
    unittest.main()
