#!/usr/bin/env bash

cat >/etc/supervisord.conf <<EOF
[supervisord]
nodaemon=true

[program:${SV_PROG_NAME}]
command=/bin/bash -l -c '${SV_CMD}'
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stdout
stderr_logfile_maxbytes=0
process_name=%(program_name)s_%(process_num)02d
EOF

/usr/bin/supervisord -c /etc/supervisord.conf
