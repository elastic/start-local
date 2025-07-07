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

function set_up() {
    sh "${CURRENT_DIR}/start-local.sh"
    # shellcheck disable=SC1090
    source "${ENV_PATH}"
}

function tear_down() {
    rm -rf "${DEFAULT_DIR}"
}

function test_uninstall_outside_installation_folder() {
    printf "yes\nno\n" | "${UNINSTALL_FILE}"
    assert_exit_code "1" "$(check_docker_service_running es-local-dev)"
    assert_exit_code "1" "$(check_docker_service_running kibana-local-dev)"
    assert_exit_code "1" "$(check_docker_service_running kibana-local-settings)"
    assert_is_directory_empty "${TEST_DIR}/${DEFAULT_DIR}"
    assert_exit_code "0" "$(check_docker_image_exists docker.elastic.co/elasticsearch/elasticsearch:"${ES_LOCAL_VERSION}")"
    assert_exit_code "0" "$(check_docker_image_exists docker.elastic.co/kibana/kibana:"${ES_LOCAL_VERSION}")"
}

function test_uninstall_in_installation_folder() {
    cd "${DEFAULT_DIR}" || exit
    printf "yes\nno\n" | ./uninstall.sh
    assert_exit_code "1" "$(check_docker_service_running es-local-dev)"
    assert_exit_code "1" "$(check_docker_service_running kibana-local-dev)"
    assert_exit_code "1" "$(check_docker_service_running kibana-local-settings)"
    assert_is_directory_empty "${DEFAULT_DIR}"
    assert_exit_code "0" "$(check_docker_image_exists docker.elastic.co/elasticsearch/elasticsearch:"${ES_LOCAL_VERSION}")"
    assert_exit_code "0" "$(check_docker_image_exists docker.elastic.co/kibana/kibana:"${ES_LOCAL_VERSION}")"
}

function test_uninstall_remove_images() {
    cd "${DEFAULT_DIR}" || exit
    printf "yes\nyes\n" | ./uninstall.sh
    assert_exit_code "1" "$(check_docker_service_running es-local-dev)"
    assert_exit_code "1" "$(check_docker_service_running kibana-local-dev)"
    assert_exit_code "1" "$(check_docker_service_running kibana-local-settings)"
    assert_is_directory_empty "${DEFAULT_DIR}"
    assert_exit_code "1" "$(check_docker_image_exists docker.elastic.co/elasticsearch/elasticsearch:"${ES_LOCAL_VERSION}")"
    assert_exit_code "1" "$(check_docker_image_exists docker.elastic.co/kibana/kibana:"${ES_LOCAL_VERSION}")"
}