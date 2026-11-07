#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only

set -e

# newer compose is a subcommand of `docker`, not a hyphenated standalone command
docker_compose() {
    if [ -x "$(command -v docker-compose)" ]; then
        docker-compose "$@"
    else
        docker compose "$@"
    fi
}

SCRIPT_DIR=$(cd "$(dirname -- "$0")" && pwd)

CGO_ENABLED=0 GOOS=linux go build -mod=vendor -tags=netgo,stringlabels -o "${SCRIPT_DIR}"/mimir "${SCRIPT_DIR}"/../../cmd/mimir
docker_compose -f "${SCRIPT_DIR}"/docker-compose.yml build mimir
docker_compose -f "${SCRIPT_DIR}"/docker-compose.yml up "$@"
