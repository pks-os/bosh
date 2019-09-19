#!/usr/bin/env bash

set -eux

REPO=$1
DESTINATION_PATH=$2

wget -q -c https://bosh.io/d/github.com/${REPO} -O ${DESTINATION_PATH}
