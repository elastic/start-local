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
ES_VERSION="8.17.0"

# include external scripts
source "${CURRENT_DIR}/tests/utility.sh"

function set_up_before_script() {
    sh "start-local.sh" "-v" "${ES_VERSION}"
    # shellcheck disable=SC1090
    source "${ENV_PATH}"
}

function tear_down_after_script() {
    yes | "${UNINSTALL_FILE}"
    rm -rf "${DEFAULT_DIR}"
}

function test_es_version_in_env_is_correct() {
    assert_file_contains "${ENV_PATH}" "ES_LOCAL_VERSION=${ES_VERSION}"
}

function test_es_version_is_correct() {  
    response=$(curl -s "$ES_LOCAL_URL" -H "Authorization: ApiKey ${ES_LOCAL_API_KEY}")
    version=$(echo "$response" | jq -r '.version.number')
    assert_equals "${ES_VERSION}" "$version"
}

