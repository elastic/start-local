#!/bin/bash
# Copyright Elasticsearch B.V. and/or licensed to Elasticsearch B.V. under one
# or more contributor license agreements. See the NOTICE file distributed with
# this work for additional information regarding copyright
# ownership. Elasticsearch B.V. licenses this file to you under
# the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#	http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

CURRENT_DIR=$(pwd)
DEFAULT_DIR="${CURRENT_DIR}/elastic-start-local"
ENV_PATH="${DEFAULT_DIR}/.env"
UNINSTALL_FILE="${DEFAULT_DIR}/uninstall.sh"

# include external scripts
source "${CURRENT_DIR}/tests/utility.sh"

function set_up_before_script() {
    # shellcheck disable=SC2086
    sh "${CURRENT_DIR}/${SCRIPT_FILE}"${SCRIPT_EXTRA_ARGS} "--fleet"
    # shellcheck disable=SC1090
    source "${ENV_PATH}"
}

function tear_down_after_script() {
    printf "yes\nno\n" | "${UNINSTALL_FILE}"
    rm -rf "${DEFAULT_DIR}"
}

function test_fleet_server_container_is_running() {
    assert_exit_code "0" "$(check_container_service_running fleet-server)"
}

function test_fleet_server_status_is_healthy() {
    response=$(curl -k -s https://localhost:8220/api/status)
    result=$(curl -k -s -o /dev/null -w "%{http_code}\n" https://localhost:8220/api/status)

    assert_equals "200" "$result"
    assert_contains "\"HEALTHY\"" "$response"
}

function test_fleet_server_agent_is_enrolled() {
    response=$(curl -s \
        -u "elastic:${ES_LOCAL_PASSWORD}" \
        -H "kbn-xsrf: true" \
        "http://localhost:5601/api/fleet/agents")

    assert_contains "fleet-server-policy" "$response"
}
