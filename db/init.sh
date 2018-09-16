#!/bin/bash

DB_DIR="/var/tmp"
DB_HOST="127.0.0.1"

mysql -u $MYSQL_USER -h $DB_HOST -e "DROP DATABASE IF EXISTS torb; CREATE DATABASE torb;"
mysql -u $MYSQL_USER -h $DB_HOST torb < "$DB_DIR/schema.sql"

mysql -u $MYSQL_USER -h $DB_HOST torb -e 'ALTER TABLE reservations DROP KEY event_id_and_sheet_id_idx'
gzip -dc "$DB_DIR/isucon8q-initial-dataset.sql.gz" | mysql -u $MYSQL_USER -h $DB_HOST torb
mysql -u $MYSQL_USER -h $DB_HOST torb -e 'ALTER TABLE reservations ADD KEY event_id_and_sheet_id_idx (event_id, sheet_id)'
