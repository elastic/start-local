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

ask_confirmation() {
  echo "Do you confirm? (yes/no)"
  read -r answer
  case "$answer" in
    yes|y|Y|Yes|YES)
      return 0  # true
      ;;
    no|n|N|No|NO)
      return 1  # false
      ;;
    *)
      echo "Please answer yes or no."
      ask_confirmation  # Ask again if the input is invalid
      ;;
  esac
}

main() {
  if [ ! -e "$script_dir/.env" ]; then
    echo "Error: I cannot find the .env file."
    echo "I cannot uninstall start-local."
  fi

  # shellcheck disable=SC1091
  . "$script_dir/.env"

  [ -n "${CONTAINER_CLI:-}" ] || { echo "CONTAINER_CLI not set"; exit 1; }
  command -v "$CONTAINER_CLI" >/dev/null 2>&1 || { echo "Error: '$CONTAINER_CLI' not found."; exit 1; }

  echo "This script will uninstall start-local."
  echo "All data will be deleted and cannot be recovered."

  if ! ask_confirmation; then
    return 0
  fi

  # TODO: Embed finalize.sh content here to avoid sourcing external script.
  "$script_dir/finalize.sh" || true
  rm -rf "$script_dir"

  echo
  echo "Do you want to remove the following images?"
  echo "- docker.elastic.co/elasticsearch/elasticsearch:${ES_LOCAL_VERSION}"

  if [ -n "${KIBANA_LOCAL_CONTAINER_NAME:-}" ]; then
    echo "- docker.elastic.co/kibana/kibana:${ES_LOCAL_VERSION}"
  fi

  if [ -n "${EDOT_LOCAL_CONTAINER_NAME:-}" ]; then
    echo "- docker.elastic.co/elastic-agent/elastic-edot-collector:${ES_LOCAL_VERSION}"
  fi

  if ! ask_confirmation; then
    echo "Elastic start-local successfully removed."
    return 0
  fi

  $CONTAINER_CLI rmi "docker.elastic.co/elasticsearch/elasticsearch:${ES_LOCAL_VERSION}" >/dev/null 2>&1 || \
    echo "Failed to remove 'docker.elastic.co/elasticsearch/elasticsearch' image."

  if [ -n "${KIBANA_LOCAL_CONTAINER_NAME:-}" ]; then
    $CONTAINER_CLI rmi "docker.elastic.co/kibana/kibana:${ES_LOCAL_VERSION}" >/dev/null 2>&1 || \
      echo "Failed to remove 'docker.elastic.co/kibana/kibana' image."
  fi

  if [ -n "${EDOT_LOCAL_CONTAINER_NAME:-}" ]; then
    $CONTAINER_CLI rmi "docker.elastic.co/elastic-agent/elastic-otel-collector:${ES_LOCAL_VERSION}" >/dev/null 2>&1 || \
      echo "Failed to remove 'docker.elastic.co/elastic-agent/elastic-otel-collector' image."
  fi

  echo "Elastic start-local successfully removed."
}

main
