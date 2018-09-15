#!/bin/bash

until mysqladmin ping --silent; do
    echo 'waiting for mysqld to be connectable...'
    sleep 3
done

