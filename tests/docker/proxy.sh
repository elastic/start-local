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
#
# Regression test for https://github.com/elastic/start-local/issues/79 (Bug 1):
# When Docker client proxy config injects HTTP_PROXY into containers, curl health
# checks route internal Docker network requests through the proxy and fail.
# The fix adds --noproxy '*' to all health check curl commands.

CURRENT_DIR=$(pwd)
DEFAULT_DIR="${CURRENT_DIR}/elastic-start-local"
ENV_PATH="${DEFAULT_DIR}/.env"
UNINSTALL_FILE="${DEFAULT_DIR}/uninstall.sh"
DOCKER_CONFIG_FILE="${HOME}/.docker/config.json"
DOCKER_CONFIG_BACKUP=""

# include external scripts
source "${CURRENT_DIR}/tests/utility.sh"

function set_up_before_script() {
    # Back up existing Docker client config (it may contain auth credentials)
    if [ -f "${DOCKER_CONFIG_FILE}" ]; then
        DOCKER_CONFIG_BACKUP=$(mktemp)
        cp "${DOCKER_CONFIG_FILE}" "${DOCKER_CONFIG_BACKUP}"
    fi

    # Inject a proxy pointing to a port where nothing listens (127.0.0.1:19999).
    # Docker propagates this as HTTP_PROXY/HTTPS_PROXY into every container.
    # Without --noproxy '*', curl health checks would fail (connection refused).
    # We preserve any existing config keys (e.g. auth) via jq merge.
    mkdir -p "${HOME}/.docker"
    local proxy_snippet='{"proxies":{"default":{"httpProxy":"http://127.0.0.1:19999","httpsProxy":"http://127.0.0.1:19999"}}}'
    if [ -n "${DOCKER_CONFIG_BACKUP}" ] && command -v jq > /dev/null 2>&1; then
        jq ". + ${proxy_snippet}" "${DOCKER_CONFIG_BACKUP}" > "${DOCKER_CONFIG_FILE}"
    else
        printf '%s\n' "${proxy_snippet}" > "${DOCKER_CONFIG_FILE}"
    fi

    # shellcheck disable=SC2086
    sh "${CURRENT_DIR}/${SCRIPT_FILE}"${SCRIPT_EXTRA_ARGS}
    # shellcheck disable=SC1090
    source "${ENV_PATH}"
}

function tear_down_after_script() {
    printf "yes\nno\n" | "${UNINSTALL_FILE}"
    rm -rf "${DEFAULT_DIR}"

    # Restore the original Docker client config
    if [ -n "${DOCKER_CONFIG_BACKUP}" ] && [ -f "${DOCKER_CONFIG_BACKUP}" ]; then
        mv "${DOCKER_CONFIG_BACKUP}" "${DOCKER_CONFIG_FILE}"
    else
        rm -f "${DOCKER_CONFIG_FILE}"
    fi
}

function test_elasticsearch_accessible_with_proxy_configured() {
    result=$(get_http_response_code "http://localhost:9200" "elastic" "${ES_LOCAL_PASSWORD}")
    assert_equals "200" "${result}"
}

function test_kibana_accessible_with_proxy_configured() {
    result=$(get_http_response_code "http://localhost:5601")
    assert_equals "200" "${result}"
}
