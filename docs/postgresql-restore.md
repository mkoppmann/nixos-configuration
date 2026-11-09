# PostgreSQL restoration

[Repository overview](../README.md) · [Backup coverage](backups.md) · [File and server recovery](recovery.md)

Use logical restoration with PostgreSQL 16 tools and the application versions appropriate to the selected data. The live cluster under `/var/lib/postgresql/16` is excluded from Borg. Application `.sql` files are custom-format archives for `pg_restore`; globals are plain SQL for `psql`.

Run in root Bash with `set -euo pipefail` and `umask 077`, with an archive extracted to `/recovery` as described in [recovery](recovery.md#extract-an-archive). Keep the affected applications, their background jobs and setup units stopped.

## Prepare roles and dependencies

```bash
systemctl start postgresql.target
systemctl is-active postgresql.service postgresql-setup.service
sudo -u postgres psql -X --host=/run/postgresql --dbname=postgres \
  --set=ON_ERROR_STOP=1 --command='\du'
sudo -u postgres psql -X --host=/run/postgresql --dbname=postgres \
  --set=ON_ERROR_STOP=1 --command='\l+'
```

Require both services to be ready. The target includes the server and separate provisioning service in the NixOS PostgreSQL module. Apollo uses peer authentication: OS user `postgres` can administer all databases without an application password.

Declarative provisioning creates the [configured databases and owning roles](backups.md#nightly-run). It does not reconstruct arbitrary role attributes, memberships, tablespaces or extension packages. Inspect the selected exports for those dependencies and verify source encoding, locale provider/collation, database settings, owners and grants. Supply matching extension binaries and required tablespace directories before restoration. Do not suppress missing-owner/ACL errors and treat that as equivalent recovery.

## Restore globals

Preserve the original export and privately review a copy:

```bash
globals_dump="/recovery/persist/var/backup/postgresql/globals/globals.sql"
globals_reviewed="/recovery/globals-reviewed.sql"
test -s "$globals_dump"
test ! -e "$globals_reviewed"
cp -- "$globals_dump" "$globals_reviewed"
chmod 0600 "$globals_reviewed"
```

The export contains role password hashes. In a private editor, reconcile existing declarative roles with exported `CREATE ROLE` statements; retain intended attributes, memberships and grants, including those for existing roles. Preserve session setup and any paired `\restrict`/`\unrestrict` commands. Review privileged roles and tablespaces before execution. On an existing cluster, apply only missing prerequisites required for the targeted application rather than replaying the whole export.

After review, on the isolated replacement:

```bash
sudo -u postgres psql -X --host=/run/postgresql --dbname=postgres \
  --no-password --set=ON_ERROR_STOP=1 < "$globals_reviewed"
```

Stop on errors. Do not print the SQL in shared diagnostics. The [PostgreSQL globals reference](https://www.postgresql.org/docs/16/app-pg-dumpall.html) describes the cluster-wide objects exported by `pg_dumpall`.

## Inspect an application archive

Choose one database from the backup inventory; this example uses Nextcloud:

```bash
restore_database=nextcloud
restore_dump="/recovery/persist/var/backup/postgresql/$restore_database.sql"
test -s "$restore_dump"
sudo -u postgres pg_restore --list < "$restore_dump" > "/recovery/$restore_database-toc.txt"
sudo -u postgres pg_restore --schema-only --create < "$restore_dump" \
  > "/recovery/$restore_database-schema.sql"
```

Review the outputs privately. Confirm the original database name inside the archive is exactly the intended destination, and check ownership, extensions, creation properties/settings and grants. Root opens the input/output files in these examples so the `postgres` process need not traverse private staging directories.

## Restore and verify

The following command **drops and recreates the database named inside the archive**. Use it only for the confirmed application database on an isolated replacement, or after preserving and stopping that application’s current state on Apollo:

```bash
sudo -u postgres pg_restore --host=/run/postgresql --dbname=postgres \
  --clean --if-exists --create --exit-on-error < "$restore_dump"
sudo -u postgres psql -X --host=/run/postgresql --dbname="$restore_database" \
  --set=ON_ERROR_STOP=1 --command='ANALYZE;'
```

`--create` selects the original name recorded in the archive; `--dbname=postgres` is the initial maintenance connection. Do not combine this restore with `--single-transaction`. A failure can leave partial state: keep clients stopped, correct the prerequisite and retry deliberately from the unchanged dump. See the [PostgreSQL 16 restore reference](https://www.postgresql.org/docs/16/app-pgrestore.html).

Check expected tables/records, owners, extensions, database properties and application file/key alignment before releasing the service. Repeat for each required database.

For a database-only exercise under a different name, create a separate empty database with matching source properties and restore without `--create`; otherwise the archive will select the original name. A database-only exercise does not validate application login, files or encryption keys.
