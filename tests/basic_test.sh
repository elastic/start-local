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
DOCKER_COMPOSE_FILE="${DEFAULT_DIR}/docker-compose.yml"
START_FILE="${DEFAULT_DIR}/start.sh"
STOP_FILE="${DEFAULT_DIR}/stop.sh"
UNINSTALL_FILE="${DEFAULT_DIR}/uninstall.sh"

# include external scripts
source "${CURRENT_DIR}/tests/utility.sh"

function set_up_before_script() {
    sh "start-local.sh"
    # shellcheck disable=SC1090
    source "${ENV_PATH}"
}

function tear_down_after_script() {
    yes | "${DEFAULT_DIR}/uninstall.sh"
    rm -rf "${DEFAULT_DIR}"
}

function test_docker_compose_file_exists() {
    assert_file_exists "${DOCKER_COMPOSE_FILE}"
}

function test_env_file_exists() {
    assert_file_exists "${ENV_PATH}"
}

function test_start_file_exists() {
    assert_file_exists "${START_FILE}"
}

function test_stop_file_exists() {
    assert_file_exists "${STOP_FILE}"
}

function test_uninstall_file_exists() {
    assert_file_exists "${UNINSTALL_FILE}"
}

function test_elasticsearch_is_running() {  
    result=$(get_http_response_code "http://localhost:9200" "elastic" "${ES_LOCAL_PASSWORD}")
    assert_equals "200" "$result"
}

function test_kibana_is_running() {  
    result=$(get_http_response_code "http://localhost:5601")
    assert_equals "200" "$result"
}

function test_login_to_kibana() {
    result=$(login_kibana "http://localhost:5601" "elastic" "${ES_LOCAL_PASSWORD}")
    assert_equals "200" "$result"
}

function test_connector_API_for_Kibana() {
    result=$(curl -X POST \
    -u elastic:"${ES_LOCAL_PASSWORD}" \
    -H 'Content-Type: application/json' \
    -H 'kbn-xsrf: true' \
    "localhost:5601/api/actions/connector" \
    -d '{"name": "my-connector", "connector_type_id": ".index", "config": {"index": "test-index"}}' \
    -o /dev/null \
    -w '%{http_code}\n' -s)

    assert_equals "200" "$result"
}

function test_API_key_exists() {
    result=$(curl -X GET \
    -u elastic:"${ES_LOCAL_PASSWORD}" \
    -H 'Content-Type: application/json' \
    "localhost:9200/_security/api_key" \
    -d "{\"name\":\"${DEFAULT_DIR}\"}" \
     -o /dev/null \
    -w '%{http_code}\n' -s    )
}