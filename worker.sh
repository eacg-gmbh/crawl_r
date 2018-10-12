#!/usr/bin/env bash

source /app/setcreds.sh

cd /app;
/usr/local/bundle/bin/bundle exec rake versioneye:$1 >> /dev/stdout 2>&1
