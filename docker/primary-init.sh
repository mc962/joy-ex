#!/bin/bash
# Runs once on first primary start (via /docker-entrypoint-initdb.d/).
# Creates the replication user and opens pg_hba.conf to replication connections.
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
  CREATE USER replicator REPLICATION LOGIN ENCRYPTED PASSWORD 'replpass';
EOSQL

echo "host replication replicator all md5" >> "$PGDATA/pg_hba.conf"
