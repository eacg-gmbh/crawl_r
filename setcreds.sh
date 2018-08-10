#!/usr/bin/env bash

# Mount your site certificate into
# /usr/local/share/ca-certificates as *.crt file
# if you want to make self signed certificates
# available

# sudo update-ca-certificates;

# Check that the environment variable has been set correctly
if [ -z "$SECRETS_BUCKET_NAME" ]; then
  echo >&2 'error: missing SECRETS_BUCKET_NAME environment variable'
  exit 1
fi

# Load the S3 secrets file contents into the environment variables
eval $(aws s3 cp s3://${SECRETS_BUCKET_NAME}/credentials.txt - | /bin/sed 's/^/export /')
