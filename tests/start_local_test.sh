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
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="${SCRIPT_DIR}/test-start-local"
DEFAULT_DIR="elastic-start-local"

# include external scripts
source "tests/utility.sh"

function set_up_before_script() {
    mkdir ${TEST_DIR}
    cd ${TEST_DIR}
    cp ${SCRIPT_DIR}/../start-local.sh ${TEST_DIR}
    sh ${TEST_DIR}/start-local.sh
    source ${TEST_DIR}/${DEFAULT_DIR}/.env
    cd ${CURRENT_DIR}
}

function tear_down_after_script() {
    cd ${TEST_DIR}/${DEFAULT_DIR}
    docker compose rm -fsv
    docker compose down -v
    cd ${SCRIPT_DIR}
    rm -rf ${TEST_DIR}
    cd ${CURRENT_DIR}
}

function test_docker_compose_file_exists() {
    assert_file_exists ${TEST_DIR}/${DEFAULT_DIR}/docker-compose.yml
}

function test_env_file_exists() {
    assert_file_exists ${TEST_DIR}/${DEFAULT_DIR}/.env
}

function test_elasticsearch_is_running() {  
    result=$(get_http_response_code "http://localhost:9200" "elastic" "${ES_LOCAL_PASSWORD}")
    assert_equals "200" $result
}

function test_kibana_is_running() {  
    result=$(get_http_response_code "http://localhost:5601")
    assert_equals "200" $result
}

function test_login_to_kibana() {
    result=$(login_kibana "http://localhost:5601" "elastic" "${ES_LOCAL_PASSWORD}")
    assert_equals "200" $result
}

function test_connector_API_for_Kibana() {
    result=$(curl -X POST \
    -u elastic:${ES_LOCAL_PASSWORD} \
    -H 'Content-Type: application/json' \
    -H 'kbn-xsrf: true' \
    "localhost:5601/api/actions/connector" \
    -d '{"name": "my-connector", "connector_type_id": ".index", "config": {"index": "test-index"}}' \
    -o /dev/null \
    -w '%{http_code}\n' -s)

    assert_equals "200" $result
}

function test_API_key_exists() {
    result=$(curl -X GET \
    -u elastic:${ES_LOCAL_PASSWORD} \
    -H 'Content-Type: application/json' \
    "localhost:9200/_security/api_key" \
    -d "{\"name\":\"${DEFAULT_DIR}\"}" \
     -o /dev/null \
    -w '%{http_code}\n' -s    )
}