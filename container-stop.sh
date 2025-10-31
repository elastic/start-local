#!/bin/sh
# --------------------------------------------------------
# Run Elasticsearch and Kibana for local testing
# Note: do not use this script in a production environment
# --------------------------------------------------------
#
# Copyright Elasticsearch B.V. and/or licensed to Elasticsearch B.V. under one
# or more contributor license agreements. See the NOTICE file distributed with
# this work for additional information regarding copyright
# ownership. Elasticsearch B.V. licenses this file to you under
# the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

set -eu

script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$script_dir/.env"

[ -n "${CONTAINER_CLI:-}" ] || { echo "CONTAINER_CLI not set"; exit 1; }
command -v "$CONTAINER_CLI" >/dev/null 2>&1 || { echo "Error: '$CONTAINER_CLI' not found."; exit 1; }

stop_container() {
  # stop_container <container-name>
  name=${1:?container name required}

  # shellcheck disable=SC2059
  printf "Stopping container '$name' ... "

  # If container doesn't exist, nothing to do.
  if ! "$CONTAINER_CLI" inspect "$name" >/dev/null 2>&1; then
    echo "done (does not exist)."
    return 0
  fi

  # Try graceful stop (ignore errors if not running).
  if "$CONTAINER_CLI" stop "$name" >/dev/null 2>&1; then
    echo "done (stopped)."
    return 0
  fi

  # Force stop.
  if "$CONTAINER_CLI" kill "$name" >/dev/null 2>&1; then
    echo "done (killed)."
    return 0
  fi

  echo "failed."
  return 1
}

stop_elasticsearch_container() {
  [ -n "${ES_LOCAL_CONTAINER_NAME:-}" ] || { echo "ES_LOCAL_CONTAINER_NAME not set"; return 1; }

  stop_container "${ES_LOCAL_CONTAINER_NAME}"
}

stop_kibana_container() {
  [ -n "${KIBANA_LOCAL_CONTAINER_NAME:-}" ] || { echo "KIBANA_LOCAL_CONTAINER_NAME not set"; return 1; }

  stop_container "${KIBANA_LOCAL_CONTAINER_NAME}"
}

stop_edot_container() {
  [ -n "${EDOT_LOCAL_CONTAINER_NAME:-}" ] || { echo "EDOT_LOCAL_CONTAINER_NAME not set"; return 1; }

  stop_container "${EDOT_LOCAL_CONTAINER_NAME}"
}

main() {
  if [ -n "${EDOT_LOCAL_CONTAINER_NAME:-}" ]; then
    stop_edot_container
  fi

  if [ -n "${KIBANA_LOCAL_CONTAINER_NAME:-}" ]; then
    stop_kibana_container
  fi

  stop_elasticsearch_container
}

main
