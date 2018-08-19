#!/usr/bin/env bash

source /app/setcreds.sh

cd /app;
/usr/local/bundle/bin/bundle exec rake versioneye:common_crawl_worker >> /dev/stdout 2>&1
