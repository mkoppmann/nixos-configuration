#!/usr/bin/env bash
set -euo pipefail
umask 077

# The systemd unit supplies a private, persistent directory and PostgreSQL PATH.
# Only systemd should invoke this on the server; one unit cannot run concurrently.
cd -- "${PG_BACKUP_DIR:?PG_BACKUP_DIR must name the globals backup directory}"

current_file=globals.sql
previous_file=globals.prev.sql
in_progress_file=globals.in-progress.sql
previous_in_progress_file=globals.prev.in-progress.sql

trap 'rm -f -- "$in_progress_file" "$previous_in_progress_file"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Remove leftovers before creating files with the current restrictive umask.
rm -f -- "$in_progress_file" "$previous_in_progress_file"

# Keep role password hashes. Never print the SQL or enable shell tracing here.
pg_dumpall --globals-only --no-password > "$in_progress_file"
if [[ ! -s "$in_progress_file" ]]; then
  echo "PostgreSQL globals export was empty; retaining the last successful backup." >&2
  exit 1
fi

# Preserve the final file until its replacement is ready. Stage the previous
# version too, so a failed copy cannot truncate an existing previous backup.
if [[ -e "$current_file" ]]; then
  cp -- "$current_file" "$previous_in_progress_file"
  chmod 0600 "$previous_in_progress_file"
  mv -f -- "$previous_in_progress_file" "$previous_file"
fi
mv -f -- "$in_progress_file" "$current_file"
