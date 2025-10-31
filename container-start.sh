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

wait_for_healthcheck() {
  # wait_for_healthcheck <container-name> <check-cmd>
  name=${1:?name required}
  shift
  check_cmd="$*"
  timeout_seconds=${HEALTHCHECK_TIMEOUT:-300}
  delay_seconds=${HEALTHCHECK_DELAY:-10}

  start_time=$(date +%s)
  # shellcheck disable=SC2059
  printf "Waiting for '${name}' ... "
  while :; do
    # Execute the check command inside the container; it should return 0 on success.
    if $CONTAINER_CLI exec "${name}" sh -c "$check_cmd" >/dev/null 2>&1 ; then
      echo "healthy."
      return 0
    fi
    now=$(date +%s)
    if [ $((now - start_time)) -ge "${timeout_seconds}" ]; then
      echo "timed out."
      return 1
    fi
    sleep "${delay_seconds}"
  done
}

start_container() {
  # start_container <container-name>
  cname=${1:?container name required}

  # shellcheck disable=SC2059
  printf "Starting container '${cname}' ... "

  if ! $CONTAINER_CLI inspect "${cname}" >/dev/null 2>&1; then
    echo "failed (does not exist)."
    return 1
  fi

  if $CONTAINER_CLI ps --format '{{.Names}}' 2>/dev/null | grep -qxF "${cname}"; then
    echo "done (already running)."
    return 0
  fi

  $CONTAINER_CLI start "${cname}" >/dev/null 2>&1 || { echo "failed."; return 1; }

  echo "done."
  return 0
}

configure_kibana_system_user_password() {
  printf "Setting up 'kibana_system' user password ... "

  cat "$script_dir/.env"
  echo "Using key: $ES_LOCAL_API_KEY"

  start_time=$(date +%s)
  timeout_seconds=60

  until \
    curl \
      -s \
      -X POST \
      "${ES_LOCAL_URL}/_security/user/kibana_system/_password" \
      -d "{\"password\":\"${KIBANA_LOCAL_PASSWORD}\"}" \
      -H "Authorization: ApiKey ${ES_LOCAL_API_KEY}" \
      -H "Content-Type: application/json" \
      | grep -q "^{}"; \
    do

    now=$(date +%s)
    if [ $((now - start_time)) -ge "${timeout_seconds}" ]; then
      printf "\n"
      echo "timed out.";
      exit 1
    fi

    sleep 2
  done

  echo "done."
}

create_elasticsearch_api_key() {
  printf "Creating Elasticsearch API key ... "

  cat "$script_dir/.env"
  echo "Using pass: $ES_LOCAL_PASSWORD"

  status=0
  response=$(curl \
    -v \
    --fail \
    -u "elastic:${ES_LOCAL_PASSWORD}" \
    -X POST \
    "${ES_LOCAL_URL}/_security/api_key" \
    -d "{\"name\": \"$ES_LOCAL_API_KEY_NAME\"}" \
    -H "Content-Type: application/json" \
  ) || status=$?

  if [ $status -ne 0 ]; then
    echo "failed."
    $CONTAINER_CLI container inspect "${ES_LOCAL_CONTAINER_NAME}"
    return 1
  fi

  echo "response: $response"

  ES_LOCAL_API_KEY="$(echo "$response" | grep -Eo '"encoded":"[A-Za-z0-9+/=]+' | grep -Eo '[A-Za-z0-9+/=]+' | tail -n 1)"
  echo "ES_LOCAL_API_KEY=${ES_LOCAL_API_KEY}" >> "$script_dir/.env"

  echo "done."
  echo "KEY: $ES_LOCAL_API_KEY"
}

check_license() {
  today=$(date +%s)

  if [ -z "${ES_LOCAL_LICENSE:-}" ] && [ "$today" -gt "$ES_LOCAL_LICENSE_EXPIRE_DATE" ]; then
    echo "---------------------------------------------------------------------"
    echo "The one-month trial period has expired. You can continue using the"
    echo "Free and open Basic license or request to extend the trial for"
    echo "another 30 days using this form:"
    echo "https://www.elastic.co/trialextension"
    echo "---------------------------------------------------------------------"
    echo "For more info about the license: https://www.elastic.co/subscriptions"
    echo
    echo "Updating the license..."

    status=$(curl \
      -s \
      -X POST \
      "${ES_LOCAL_URL}/_license/start_basic?acknowledge=true" \
      -H "Authorization: ApiKey ${ES_LOCAL_API_KEY}" \
      -o /dev/null \
      -w '%{http_code}\n' \
    )

    if [ "$status" = "200" ]; then
      echo "✅ Basic license successfully installed"
      echo "ES_LOCAL_LICENSE=basic" >> .env
    else 
      echo "Error: Failed to activate Basic license (HTTP status code $status)."
      exit 1
    fi

    echo
  fi
}

main() {
  # Check disk space
  available_gb=$(($(df -k / | awk 'NR==2 {print $4}') / 1024 / 1024))
  required=$(echo "${ES_LOCAL_DISK_SPACE_REQUIRED}" | grep -Eo '[0-9]+')
  if [ "$available_gb" -lt "$required" ]; then
    echo "----------------------------------------------------------------------------"
    echo "WARNING: Disk space is below the ${required} GB limit. Elasticsearch will be"
    echo "executed in read-only mode. Please free up disk space to resolve this issue."
    echo "----------------------------------------------------------------------------"
    echo "Press ENTER to confirm."
    # shellcheck disable=SC2034
    read -r line
  fi

  HEALTHCHECK_TIMEOUT=${HEALTHCHECK_TIMEOUT:-300}
  HEALTHCHECK_DELAY=${HEALTHCHECK_DELAY:-10}

  # Start Elasticsearch and wait for it to respond to REST requests.
  start_container "${ES_LOCAL_CONTAINER_NAME}" || exit 1
  es_check="curl --output /dev/null --silent --head --fail -u elastic:${ES_LOCAL_PASSWORD} http://elasticsearch:9200"
  wait_for_healthcheck "${ES_LOCAL_CONTAINER_NAME}" "$es_check" || exit 1

  # Create Elasticsearch API key for local use on first start.
  if [ -z "${ES_LOCAL_API_KEY:-}" ]; then
    create_elasticsearch_api_key
  fi

  check_license

  if [ -n "${KIBANA_LOCAL_CONTAINER_NAME:-}" ]; then
    # Configure Kibana system_user password before starting Kibana.
    configure_kibana_system_user_password

    # Start Kibana and wait for it to respond to REST requests.
    start_container "${KIBANA_LOCAL_CONTAINER_NAME}" || exit 1
    kibana_check="curl -s -I http://kibana:5601 | grep -q 'HTTP/1.1 302 Found'"
    wait_for_healthcheck "${KIBANA_LOCAL_CONTAINER_NAME}" "$kibana_check" || exit 1
  fi

  if [ -n "${EDOT_LOCAL_CONTAINER_NAME:-}" ]; then
    # Start edot-collector and wait for it to respond to requests.
    start_container "${EDOT_LOCAL_CONTAINER_NAME}" || exit 1
    edot_check="echo -n > /dev/tcp/127.0.0.1/4317"
    wait_for_healthcheck "${EDOT_LOCAL_CONTAINER_NAME}" "$edot_check" || exit 1
  fi
}

main
