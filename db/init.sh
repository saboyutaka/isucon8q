#!/bin/bash

ROOT_DIR=/var/tmp
DB_DIR="$ROOT_DIR"

mysql -uroot -e "DROP DATABASE IF EXISTS torb; CREATE DATABASE torb;"
mysql -uroot torb < "$DB_DIR/schema.sql"

mysql -uroot torb -e 'ALTER TABLE reservations DROP KEY event_id_and_sheet_id_idx'
gzip -dc "$DB_DIR/isucon8q-initial-dataset.sql.gz" | mysql -uroot torb
mysql -uroot torb -e 'ALTER TABLE reservations ADD KEY event_id_and_sheet_id_idx (event_id, sheet_id)'
