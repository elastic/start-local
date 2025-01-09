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
START_LOCAL_PATH="${SCRIPT_DIR}/../start-local.sh"
TEST_DIR="${SCRIPT_DIR}/test-start-local"
DEFAULT_DIR="elastic-start-local"
ENV_PATH="${TEST_DIR}/${DEFAULT_DIR}/.env"

# include external scripts
source "tests/utility.sh"

function set_up_before_script() {
    mkdir "${TEST_DIR}"
    cd "${TEST_DIR}" || exit
    cp "${START_LOCAL_PATH}" "${TEST_DIR}"
    sh "${TEST_DIR}/start-local.sh"
    # shellcheck disable=SC1090
    source "${ENV_PATH}"
    cd "${CURRENT_DIR}" || exit
}

function tear_down_after_script() {
    cd "${TEST_DIR}/${DEFAULT_DIR}" || exit
    docker compose rm -fsv
    docker compose down -v
    cd "${SCRIPT_DIR}" || exit
    rm -rf "${TEST_DIR}"
    cd "${CURRENT_DIR}" || exit
}

function test_stop() {
    "${TEST_DIR}/${DEFAULT_DIR}/stop.sh"

    assert_exit_code "1" "$(check_docker_service_running es-local-dev)"
    assert_exit_code "1" "$(check_docker_service_running kibana-local-dev)"
    assert_exit_code "1" "$(check_docker_service_running kibana_settings)"
}

function test_start() {
    "${TEST_DIR}/${DEFAULT_DIR}/start.sh"

    assert_exit_code "0" "$(check_docker_service_running es-local-dev)"
    assert_exit_code "0" "$(check_docker_service_running kibana-local-dev)"
}