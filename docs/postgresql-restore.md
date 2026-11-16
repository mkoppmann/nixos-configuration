# PostgreSQL restoration

[Repository overview](../README.md) · [Backup coverage](backups.md) · [File and server recovery](recovery.md)

Use logical restoration with PostgreSQL 16 tools and the application versions appropriate to the selected data. Borg excludes the live cluster under `/var/lib/postgresql/16`. Application `.sql` files are custom-format archives for `pg_restore`. Globals are plain SQL for `psql`.

Run the commands in root Bash with `set -euo pipefail` and `umask 077`. Extract an archive to `/recovery` first, as described in [recovery](recovery.md#extract-an-archive). Keep the affected applications, their background jobs and setup units stopped.

## Prepare roles and dependencies

```bash
systemctl start postgresql.target
systemctl is-active postgresql.service postgresql-setup.service
sudo -u postgres psql -X --host=/run/postgresql --dbname=postgres \
  --set=ON_ERROR_STOP=1 --command='\du'
sudo -u postgres psql -X --host=/run/postgresql --dbname=postgres \
  --set=ON_ERROR_STOP=1 --command='\l+'
```

Both services must be ready. The target includes the server and the separate provisioning service of the NixOS PostgreSQL module. Apollo uses peer authentication: OS user `postgres` can administer all databases without an application password.

Declarative provisioning creates the [configured databases and owning roles](backups.md#nightly-run). On a new cluster, it creates Synapse’s database with the collation `C` that Synapse requires. It does not reconstruct arbitrary role attributes, memberships, tablespaces or extension packages. Inspect the selected exports for those dependencies. Verify source encoding, locale provider and collation, database settings, owners and grants. Supply matching extension binaries and required tablespace directories before restoration. Do not suppress missing-owner or ACL errors and then treat the result as an equivalent recovery.

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

The export contains role password hashes. In a private editor, reconcile existing declarative roles with exported `CREATE ROLE` statements. Retain intended attributes, memberships and grants, including those for existing roles. Preserve session setup and any paired `\restrict`/`\unrestrict` commands. Review privileged roles and tablespaces before execution. On an existing cluster, apply only the missing prerequisites that the targeted application requires. Do not replay the whole export.

After review, on the isolated replacement:

```bash
sudo -u postgres psql -X --host=/run/postgresql --dbname=postgres \
  --no-password --set=ON_ERROR_STOP=1 < "$globals_reviewed"
```

Stop on errors. Do not print the SQL in shared diagnostics. The [PostgreSQL globals reference](https://www.postgresql.org/docs/16/app-pg-dumpall.html) describes the cluster-wide objects that `pg_dumpall` exports.

## Inspect an application archive

Choose one database from the backup inventory. This example uses Nextcloud:

```bash
restore_database=nextcloud
restore_dump="/recovery/persist/var/backup/postgresql/$restore_database.sql"
test -s "$restore_dump"
sudo -u postgres pg_restore --list < "$restore_dump" > "/recovery/$restore_database-toc.txt"
sudo -u postgres pg_restore --schema-only --create < "$restore_dump" \
  > "/recovery/$restore_database-schema.sql"
```

Review the outputs privately. Check that the original database name inside the archive is exactly the intended destination. Check ownership, extensions, creation properties and settings, and grants. Root opens the input and output files in these examples, so the `postgres` process need not traverse private staging directories.

## Restore and verify

Warning: the following command drops and recreates the database named inside the archive. Use it only for the confirmed application database. Run it on an isolated replacement, or on Apollo after you preserved that application’s current state and stopped the application:

```bash
sudo -u postgres pg_restore --host=/run/postgresql --dbname=postgres \
  --clean --if-exists --create --exit-on-error < "$restore_dump"
sudo -u postgres psql -X --host=/run/postgresql --dbname="$restore_database" \
  --set=ON_ERROR_STOP=1 --command='ANALYZE;'
```

`--create` selects the original name recorded in the archive. It recreates the database with the encoding and locale recorded there. Synapse’s database therefore keeps the collation `C`, whatever the dropped database had. `--dbname=postgres` is the initial maintenance connection. Do not combine this restore with `--single-transaction`. A failure can leave partial state. In that case, keep clients stopped, correct the prerequisite and retry deliberately from the unchanged dump. The [PostgreSQL 16 restore reference](https://www.postgresql.org/docs/16/app-pgrestore.html) describes the options.

Before you release the service, check expected tables and records, owners, extensions and database properties. Also check that the application’s files and keys match the database. Repeat for each required database.

For a database-only exercise under a different name, create a separate empty database with matching source properties. Restore without `--create`. Otherwise the archive selects the original name. A database-only exercise does not validate application login, files or encryption keys.
