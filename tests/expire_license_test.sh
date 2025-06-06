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

# include external scripts
source "${CURRENT_DIR}/tests/utility.sh"

function set_up_before_script() {
    sh "${CURRENT_DIR}/start-local.sh"
    # shellcheck disable=SC1090
    source "${ENV_PATH}"
}

function tear_down_after_script() {
    printf "yes\nno\n" | "${DEFAULT_DIR}/uninstall.sh"
    rm -rf "${DEFAULT_DIR}"
}

function test_start_with_expired_license() {
    # Check license is trial
    license=$(get_elasticsearch_license)
    assert_equals "$license" "trial"
    
    # Change the expire date in start.sh
    sed -i -E 's/-gt [0-9]+/-gt 1/' "${DEFAULT_DIR}/start.sh"
    "${DEFAULT_DIR}/start.sh"

    # Check license is basic
    license=$(get_elasticsearch_license)
    assert_equals "$license" "basic"
}

function get_elasticsearch_license() {
    local response
    response=$(curl -X GET "$ES_LOCAL_URL/_license" -H "Authorization: ApiKey ${ES_LOCAL_API_KEY}")
    echo "$response" | jq -r '.license.type'
}