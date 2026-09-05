#!/bin/bash
set -e

for i in 0 1 2; do
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    CREATE DATABASE sparkoperator_$i;
    CREATE DATABASE spark_ephemeral_$i;
EOSQL
done
