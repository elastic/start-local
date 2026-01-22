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
UNINSTALL_FILE="${DEFAULT_DIR}/uninstall.sh"

# include external scripts
source "${CURRENT_DIR}/tests/utility.sh"

function set_up_before_script() {
    # shellcheck disable=SC2086
    sh "${CURRENT_DIR}/${SCRIPT_FILE}"${SCRIPT_EXTRA_ARGS} "--edot"
}

function tear_down_after_script() {
    printf "yes\nno\n" | "${UNINSTALL_FILE}"
    rm -rf "${DEFAULT_DIR}"
}

function test_edot_collector_is_running() {
    result=$(curl -X POST http://localhost:4318/v1/logs \
  -H "Content-Type: application/json" \
  -d '{
    "Timestamp": "1634630400000",
    "ObservedTimestamp": "1634630401000",
    "TraceId": "abcd1234",
    "SpanId": "efgh5678",
    "SeverityText": "DEBUG",
    "SeverityNumber": "5",
    "Body": "Testing log to assert collector OTLP endpoint",
    "Resource": {
      "service.name": "start-local-testing"
    },
    "InstrumentationScope": {},
    "Attributes": {}
  }' \
  -o /dev/null -s -w "%{http_code}\n")

    opamp_result=$(curl http://localhost:4320/v1/opamp \
    -H 'content-type:application/x-protobuf' \
    -d '' \
    -o /dev/null -sw "%{http_code}\n")

    assert_equals "200" "$result"
    assert_equals "200" "$opamp_result"
}

