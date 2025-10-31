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

remove_bridged_network() {
  [ -n "${CONTAINER_NETWORK_NAME:-}" ] || { echo "CONTAINER_NETWORK_NAME not set"; return 1; }

  # shellcheck disable=SC2059
  printf "Removing network '${CONTAINER_NETWORK_NAME}' ... "

  if ! "$CONTAINER_CLI" network inspect "${CONTAINER_NETWORK_NAME}" >/dev/null 2>&1; then
    echo "done (does not exist)."
    return 0
  fi

  # Try graceful removal the network; if it's in use this will typically fail.
  "$CONTAINER_CLI" network rm "${CONTAINER_NETWORK_NAME}" >/dev/null 2>&1 || true

  # Force remove.
  if "$CONTAINER_CLI" network rm -f "${CONTAINER_NETWORK_NAME}" >/dev/null 2>&1; then
    echo "done (removed)."
    return 0
  fi

  echo "failed."

  return 1
}

remove_volume() {
  # remove_volumes <volume>
  [ -n "${1:-}" ] || { echo "Usage: remove_volume <volume-name>"; return 1; }

  vol="$1"

  # shellcheck disable=SC2059
  printf "Removing volume '$vol' ... "

  if ! "$CONTAINER_CLI" volume inspect "$vol" >/dev/null 2>&1; then
    echo "done (does not exist)."
    return 0
  fi

  if "$CONTAINER_CLI" volume rm -f "$vol" >/dev/null 2>&1; then
    echo "done (removed)."
    return 0
  fi

  echo "failed."

  # If removal failed, attempt to list attached containers to help the user.
  echo "Volume '${vol}' may be in use."
  echo "Attached containers (if any):"
  "$CONTAINER_CLI" volume inspect "${vol}" 2>/dev/null || true
  echo "Disconnect or stop containers and retry: '${CONTAINER_CLI} volume rm -f ${vol}'"

  return 1
}

remove_container() {
  # remove_container <container-name>
  name=${1:?container name required}

  # shellcheck disable=SC2059
  printf "Removing container '$name' ... "

  # If container doesn't exist, nothing to do.
  if ! "$CONTAINER_CLI" inspect "$name" >/dev/null 2>&1; then
    echo "done (does not exist)."
    return 0
  fi

  # Try graceful stop (ignore errors if not running).
  "$CONTAINER_CLI" stop "$name" >/dev/null 2>&1 || true

  # Force remove (will stop if still running).
  if "$CONTAINER_CLI" rm -f "$name" >/dev/null 2>&1; then
    echo "done (removed)."
    return 0
  fi

  echo "failed."
  return 1
}

remove_elasticsearch_container() {
  [ -n "${ES_LOCAL_CONTAINER_NAME:-}" ] || { echo "ES_LOCAL_CONTAINER_NAME not set"; return 1; }

  remove_container "${ES_LOCAL_CONTAINER_NAME}"
  remove_volume dev-elasticsearch
}

remove_kibana_container() {
  [ -n "${KIBANA_LOCAL_CONTAINER_NAME:-}" ] || { echo "KIBANA_LOCAL_CONTAINER_NAME not set"; return 1; }

  remove_container "${KIBANA_LOCAL_CONTAINER_NAME}"
  remove_volume dev-kibana
}

remove_edot_container() {
  [ -n "${EDOT_LOCAL_CONTAINER_NAME:-}" ] || { echo "EDOT_LOCAL_CONTAINER_NAME not set"; return 1; }

  remove_container "${EDOT_LOCAL_CONTAINER_NAME}"
}

main() {
  if [ -n "${EDOT_LOCAL_CONTAINER_NAME:-}" ]; then
    remove_edot_container
  fi

  if [ -n "${KIBANA_LOCAL_CONTAINER_NAME:-}" ]; then
    remove_kibana_container
  fi

  remove_elasticsearch_container
  remove_bridged_network
}

main
