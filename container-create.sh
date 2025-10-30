#!/bin/sh
# --------------------------------------------------------
# Run Elasticsearch and Kibana for local testing
# Note: do not use this script in a production environment
# --------------------------------------------------------
#
# Copyright Elasticsearch B.V. and/or licensed to Elasticsearch B.V. under one
# or more contributor license agreements. See the NOTICE file distributed with
# this work for additional information regarding copyright
# ownership. Elasticsearch B.V. licenses this file to you under
# the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

set -eu

script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$script_dir/.env"

[ -n "${CONTAINER_CLI:-}" ] || { echo "CONTAINER_CLI not set"; exit 1; }
command -v "$CONTAINER_CLI" >/dev/null 2>&1 || { echo "Error: '$CONTAINER_CLI' not found."; exit 1; }

# Detect if running on LXC container
detect_lxc() {
  # Check /proc/1/environ for LXC container identifier
  if grep -qa "container=lxc" /proc/1/environ 2>/dev/null; then
    return 0
  fi

  # Check /proc/self/cgroup for LXC references
  if grep -q "lxc" /proc/self/cgroup 2>/dev/null; then
    return 0
  fi

  # Check for LXC in /sys/fs/cgroup
  if grep -q "lxc" /sys/fs/cgroup/* 2>/dev/null; then  
    return 0
  fi

  # Use systemd-detect-virt if available
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    if [ "$(systemd-detect-virt)" = "lxc" ]; then
      return 0
    fi
  fi

  return 1
}

create_bridged_network() {
  [ -n "${CONTAINER_NETWORK_NAME:-}" ] || { echo "CONTAINER_NETWORK_NAME not set"; return 1; }

  # shellcheck disable=SC2059
  printf "Creating network '$CONTAINER_NETWORK_NAME' ... "

  # If network already exists, nothing to do.
  if "$CONTAINER_CLI" network inspect "$CONTAINER_NETWORK_NAME" >/dev/null 2>&1; then
    echo "done (already exists)."
    return 0
  fi

  # Create a bridged network and let the CLI/CNI pick the default subnet/gateway.
  if "$CONTAINER_CLI" network create --driver bridge "$CONTAINER_NETWORK_NAME" >/dev/null 2>&1; then
    echo "done (created)."
    return 0
  fi

  # Some Podman versions use CNI and accept 'podman network create' without --driver.
  if [ "$CONTAINER_CLI" = "podman" ]; then
    if "$CONTAINER_CLI" network create "$CONTAINER_NETWORK_NAME" >/dev/null 2>&1; then
      echo "done (created)."
      return 0
    fi
  fi

  echo "failed."
  return 1
}

create_elasticsearch_container() {
  [ -n "${CONTAINER_NETWORK_NAME:-}" ] || { echo "CONTAINER_NETWORK_NAME not set"; return 1; }
  [ -n "${ES_LOCAL_VERSION:-}" ] || { echo "ES_LOCAL_VERSION not set"; return 1; }
  [ -n "${ES_LOCAL_CONTAINER_NAME:-}" ] || { echo "ES_LOCAL_CONTAINER_NAME not set"; return 1; }
  [ -n "${ES_LOCAL_PORT:-}" ] || { echo "ES_LOCAL_PORT not set"; return 1; }
  [ -n "${ES_LOCAL_PASSWORD:-}" ] || { echo "ES_LOCAL_PASSWORD not set"; return 1; }

  ES_LOCAL_JAVA_OPTS=${ES_LOCAL_JAVA_OPTS:-}
  ES_LOCAL_DISK_SPACE_REQUIRED=${ES_LOCAL_DISK_SPACE_REQUIRED:-85%}

  image="docker.elastic.co/elasticsearch/elasticsearch:${ES_LOCAL_VERSION}"

  # shellcheck disable=SC2059
  printf "Creating container '${ES_LOCAL_CONTAINER_NAME}' from image '${image}' ... "

  # If container exists, do nothing.
  if "$CONTAINER_CLI" ps -a --format '{{.Names}}' 2>/dev/null | grep -qxF "${ES_LOCAL_CONTAINER_NAME}"; then
    echo "done (already exist)."
    return 0
  fi

  # Add ulimit for memlock on non-LXC hosts.
  ulimit_args=""
  if ! detect_lxc >/dev/null 2>&1; then
    ulimit_args="--ulimit memlock=-1:-1"
  fi

  # Create container.
  # shellcheck disable=SC2086
  "$CONTAINER_CLI" create \
    --name "${ES_LOCAL_CONTAINER_NAME}" \
    --network "${CONTAINER_NETWORK_NAME}" \
    --hostname elasticsearch \
    --network-alias elasticsearch \
    -p "127.0.0.1:${ES_LOCAL_PORT}:9200" \
    -v "dev-elasticsearch:/usr/share/elasticsearch/data" \
    -e "discovery.type=single-node" \
    -e "ELASTIC_PASSWORD=${ES_LOCAL_PASSWORD}" \
    -e "xpack.security.enabled=true" \
    -e "xpack.security.http.ssl.enabled=false" \
    -e "xpack.license.self_generated.type=trial" \
    -e "xpack.ml.use_auto_machine_memory_percent=true" \
    -e "ES_JAVA_OPTS=${ES_LOCAL_JAVA_OPTS}" \
    -e "cluster.routing.allocation.disk.watermark.low=${ES_LOCAL_DISK_SPACE_REQUIRED}" \
    -e "cluster.routing.allocation.disk.watermark.high=${ES_LOCAL_DISK_SPACE_REQUIRED}" \
    -e "cluster.routing.allocation.disk.watermark.flood_stage=${ES_LOCAL_DISK_SPACE_REQUIRED}" \
    $ulimit_args \
    "${image}" >/dev/null 2>&1 || {
      echo "failed."
      return 1
    }

  echo "done (created)."
  return 0
}

create_kibana_container() {
  [ -n "${CONTAINER_NETWORK_NAME:-}" ] || { echo "CONTAINER_NETWORK_NAME not set"; return 1; }
  [ -n "${ES_LOCAL_VERSION:-}" ] || { echo "ES_LOCAL_VERSION not set"; return 1; }
  [ -n "${KIBANA_LOCAL_CONTAINER_NAME:-}" ] || { echo "KIBANA_LOCAL_CONTAINER_NAME not set"; return 1; }
  [ -n "${KIBANA_LOCAL_PORT:-}" ] || { echo "KIBANA_LOCAL_PORT not set"; return 1; }
  [ -n "${KIBANA_LOCAL_PASSWORD:-}" ] || { echo "KIBANA_LOCAL_PASSWORD not set"; return 1; }

  ES_LOCAL_PORT=${ES_LOCAL_PORT:-9200}
  telemetry_host_path="$script_dir/config/telemetry.yml"

  image="docker.elastic.co/kibana/kibana:${ES_LOCAL_VERSION}"

  # shellcheck disable=SC2059
  printf "Creating container '${KIBANA_LOCAL_CONTAINER_NAME}' from image '${image}' ... "

  # Do nothing if container already exists.
  if "$CONTAINER_CLI" ps -a --format '{{.Names}}' 2>/dev/null | grep -qxF "${KIBANA_LOCAL_CONTAINER_NAME}"; then
    echo "done (already exists)."
    return 0
  fi

  # Optional telemetry mount if file exists.
  if [ -f "${telemetry_host_path}" ]; then
    telemetry_mount="-v ${telemetry_host_path}:/usr/share/kibana/config/telemetry.yml:ro"
  else
    telemetry_mount=""
  fi

  # shellcheck disable=SC2086
  $CONTAINER_CLI create \
    --name "${KIBANA_LOCAL_CONTAINER_NAME}" \
    --network "${CONTAINER_NETWORK_NAME}" \
    --hostname kibana \
    --network-alias kibana \
    -p "127.0.0.1:${KIBANA_LOCAL_PORT}:5601" \
    -v "dev-kibana:/usr/share/kibana/data" \
    $telemetry_mount \
    -e "SERVER_NAME=kibana" \
    -e "ELASTICSEARCH_HOSTS=http://elasticsearch:9200" \
    -e "ELASTICSEARCH_USERNAME=kibana_system" \
    -e "ELASTICSEARCH_PASSWORD=${KIBANA_LOCAL_PASSWORD}" \
    -e "XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY=${KIBANA_ENCRYPTION_KEY:-}" \
    -e "ELASTICSEARCH_PUBLICBASEURL=http://localhost:${ES_LOCAL_PORT}" \
    -e "XPACK_SPACES_DEFAULTSOLUTION=es" \
    "${image}" >/dev/null 2>&1 || {
      echo "failed."
      return 1
    }

  echo "done (created)."
  return 0
}

create_edot_container() {
  [ -n "${CONTAINER_NETWORK_NAME:-}" ] || { echo "CONTAINER_NETWORK_NAME not set"; return 1; }
  [ -n "${ES_LOCAL_VERSION:-}" ] || { echo "ES_LOCAL_VERSION not set"; return 1; }
  [ -n "${EDOT_LOCAL_CONTAINER_NAME:-}" ] || { echo "EDOT_LOCAL_CONTAINER_NAME not set"; return 1; }

  edot_config_host_path="$script_dir/config/edot-collector/config.yaml"
  image="docker.elastic.co/elastic-agent/elastic-otel-collector:${ES_LOCAL_VERSION}"

  # shellcheck disable=SC2059
  printf "Creating container '${EDOT_LOCAL_CONTAINER_NAME}' from image '${image}' ... "

  # If container exists, do nothing.
  if "$CONTAINER_CLI" ps -a --format '{{.Names}}' 2>/dev/null | grep -qxF "${EDOT_LOCAL_CONTAINER_NAME}"; then
    echo "done (already exists)."
    return 0
  fi

  # We use --env-file to allow the container to access ES_LOCAL_API_KEY - which is not initialized
  # at this point.
  
  $CONTAINER_CLI create \
    --name "${EDOT_LOCAL_CONTAINER_NAME}" \
    --network "${CONTAINER_NETWORK_NAME}" \
    --hostname edot-collector \
    --network-alias edot-collector \
    -p "4317:4317" \
    -p "4318:4318" \
    -v "${edot_config_host_path}:/etc/otelcol-contrib/config.yaml:ro" \
    --env-file "$script_dir/.env" \
    "${image}" \
    --config=/etc/otelcol-contrib/config.yaml >/dev/null 2>&1 || {
      echo "failed."
      return 1
    }

  echo "done (created)."
  return 0
}

main() {
  create_bridged_network
  create_elasticsearch_container

  if [ -n "${KIBANA_LOCAL_CONTAINER_NAME:-}" ]; then
    create_kibana_container
  fi

  if [ -n "${EDOT_LOCAL_CONTAINER_NAME:-}" ]; then
    create_edot_container
  fi
}

main
