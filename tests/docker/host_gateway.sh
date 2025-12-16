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
    python -m http.server 8000 &
    PYTHON_HTTP_SERVER_PID=$!
    disown "$PYTHON_HTTP_SERVER_PID"
    sleep 2
    sh "${CURRENT_DIR}/${SCRIPT_FILE}"
    # shellcheck disable=SC1090
    source "${ENV_PATH}"
}

function tear_down_after_script() {
    printf "yes\nno\n" | "${UNINSTALL_FILE}"
    rm -rf "${DEFAULT_DIR}"
    kill "${PYTHON_HTTP_SERVER_PID}" 2>/dev/null
    wait "${PYTHON_HTTP_SERVER_PID}" 2>/dev/null
}

function test_elasticsearch_host_docker_internal() {
    status_code=$(docker exec "${ES_LOCAL_CONTAINER_NAME}" \
        curl -s -o /dev/null -w "%{http_code}" http://host.docker.internal:8000)

    # Assert HTTP 200
    assert_equals "200" "$status_code"
}

function test_kibana_host_docker_internal() {
    status_code=$(docker exec "${KIBANA_LOCAL_CONTAINER_NAME}" \
        curl -s -o /dev/null -w "%{http_code}" http://host.docker.internal:8000)

    # Assert HTTP 200
    assert_equals "200" "$status_code"
}

function test_elasticsearch_model-runner_docker_internal() {
    status_code=$(docker exec "${ES_LOCAL_CONTAINER_NAME}" \
        curl -s -o /dev/null -w "%{http_code}" http://model-runner.docker.internal:8000)

    # Assert HTTP 200
    assert_equals "200" "$status_code"
}

function test_kibana_model-runner_docker_internal() {
    status_code=$(docker exec "${KIBANA_LOCAL_CONTAINER_NAME}" \
        curl -s -o /dev/null -w "%{http_code}" http://model-runner.docker.internal:8000)

    # Assert HTTP 200
    assert_equals "200" "$status_code"
}