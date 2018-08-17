#!/usr/bin/env bash

source /app/setcreds.sh

cd /app;
/usr/local/bundle/bin/bundle exec rake versioneye:scheduler_crawl_r >> /dev/stdout 2>&1