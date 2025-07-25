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

function tear_down() {
    if [ -e "${UNINSTALL_FILE}" ]; then
        printf "yes\nno\n" | "${UNINSTALL_FILE}"
        rm -rf "${DEFAULT_DIR}"
    fi
}

function test_with_es_local_password_env() {
    password="supersecret"
    ES_LOCAL_PASSWORD="${password}" sh -c "${CURRENT_DIR}/start-local.sh"
    assert_file_contains "${ENV_PATH}" "ES_LOCAL_PASSWORD=${password}"
    result=$(get_http_response_code "http://localhost:9200" "elastic" "${password}")
    assert_equals "200" "$result"
}

function test_with_es_local_dir_env() {
    dir="test-another-folder"
    DEFAULT_DIR="${CURRENT_DIR}/${dir}"
    UNINSTALL_FILE="${DEFAULT_DIR}/uninstall.sh"
    ES_LOCAL_DIR="${dir}" sh -c "${CURRENT_DIR}/start-local.sh"
    assert_directory_exists "${DEFAULT_DIR}"
    assert_file_exists "${UNINSTALL_FILE}"
}