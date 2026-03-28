#!/bin/bash
# Replica container entrypoint.
# Waits for the primary to be ready, clones it via pg_basebackup on first start
# (-R writes primary_conninfo and creates standby.signal automatically),
# then hands off to the standard postgres entrypoint.
set -e

PRIMARY_HOST="${PRIMARY_HOST:-postgres}"
PGUSER="${POSTGRES_USER:-joy}"

until pg_isready -h "$PRIMARY_HOST" -U "$PGUSER" -q; do
  sleep 1
done

if [ ! -f "$PGDATA/PG_VERSION" ]; then
  PGPASSWORD=replpass pg_basebackup \
    -h "$PRIMARY_HOST" \
    -U replicator \
    -D "$PGDATA" \
    -P --wal-method=stream -R
fi

exec docker-entrypoint.sh postgres
