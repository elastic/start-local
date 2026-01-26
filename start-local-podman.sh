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
#	http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

set -eu

script_dir="$(cd "$(dirname "$0")" && pwd)"

### Helper functions ###############################################################################

# Returns 0 if command exists in PATH.
available() {
  command -v "$1" >/dev/null 2>&1
}

# Checks the available disk space in GB
# parameter: required size in GB
check_disk_space_gb() {
  required=$1
  available_gb=$(($(df -k / | awk 'NR==2 {print $4}') / 1024 / 1024))
  if [ "$available_gb" -lt "$required" ]; then
    echo "Error: Only '${available_gb}' GB disk space available; '${required}' GB is required."
    exit 1
  fi
}


# Check if a container is runnning
# parameter: the name of the container
check_container_running() {
  container_name=$1

  if "$container_cli" ps -a --format '{{.Names}}' 2>/dev/null | grep -qxF "${container_name}"; then
    echo "The container '$container_name' does already exist!"
    echo "To remove the container run the following command:"
    echo
    echo "$container_cli rm $container_name"
    exit 1
  fi
}

# Generates a random password with letters and numbers
# parameter: size of the password (default is 8 characters)
random_password() {
  LENGTH="${1:-8}"
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c "${LENGTH}"
}

# Check for ARM64 architecture
is_arm64() {
  arch="$(uname -m)"
  if [ "$arch" = "arm64" ] || [ "$arch" = "aarch64" ]; then
    return 0 # Return 0 (true)
  else
    return 1 # Return 1 (false)
  fi
}

# Alternative to sort -V, which is not available in BSD-based systems (e.g., macOS)
version_sort() {
  awk -F'.' '
  {
      printf("%d %d %d %s\n", $1, $2, $3, $0)
  }' | sort -n -k1,1 -k2,2 -k3,3 | awk '{print $4}'
}

# Function to check if the format is a valid semantic version (major.minor.patch)
is_valid_version() {
  echo "$1" | grep -E -q '^[0-9]+\.[0-9]+\.[0-9]+$'
}

# Compare versions
# parameter 1: version to compare
# parameter 2: version to compare
compare_versions() {
  v1=$1
  v2=$2

  original_ifs="$IFS"
  IFS='.'
  # shellcheck disable=SC2086
  set -- $v1; v1_major=${1:-0}; v1_minor=${2:-0}; v1_patch=${3:-0}
  IFS='.'
  # shellcheck disable=SC2086
  set -- $v2; v2_major=${1:-0}; v2_minor=${2:-0}; v2_patch=${3:-0}
  IFS="$original_ifs"

  [ "$v1_major" -lt "$v2_major" ] && echo "lt" && return 0
  [ "$v1_major" -gt "$v2_major" ] && echo "gt" && return 0

  [ "$v1_minor" -lt "$v2_minor" ] && echo "lt" && return 0
  [ "$v1_minor" -gt "$v2_minor" ] && echo "gt" && return 0

  [ "$v1_patch" -lt "$v2_patch" ] && echo "lt" && return 0
  [ "$v1_patch" -gt "$v2_patch" ] && echo "gt" && return 0

  echo "eq"
}

# Get the latest stable version of Elasticsearch
# Note: It removes all the beta or candidate releases from the list
# but includes the GA releases (e.g. new major)
get_latest_version() {
  versions="$(curl -s "https://artifacts.elastic.co/releases/stack.json")"
  latest_version=$(echo "$versions" | awk -F'"' '/"version": *"/ {print $4}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+( GA)?$' | version_sort | tail -n 1)
  # Remove the GA prefix from the version, if present
  latest_version=$(echo "$latest_version" | awk '{ gsub(/ GA$/, "", $0); print }')

  # Check if the latest version is empty
  if [ -z "$latest_version" ]; then
    echo "Error: the latest Elasticsearch version is empty"
    exit 1
  fi
  # Check if the latest version is valid
  if ! is_valid_version "$latest_version"; then
    echo "Error: {$latest_version} is not a valid Elasticsearch stable version"
    exit 1
  fi

  echo "$latest_version"
}

# Revert the status, removing containers, volumes, network and folder
cleanup() {
  if [ -d "$installation_folder" ]; then
    if [ -f "uninstall.sh" ]; then
      "$installation_folder/stop.sh" >/dev/null 2>&1 || true
      "$installation_folder/uninstall.sh" >/dev/null 2>&1 || true
    fi

    rm -rf "$installation_folder"
  fi
}

get_os_info() {
  if [ -f /etc/os-release ]; then
      # Most modern Linux distributions have this file
      . /etc/os-release
      echo "Distribution: $NAME"
      echo "Version: $VERSION"
  elif [ -f /etc/lsb-release ]; then
      # For older distributions using LSB (Linux Standard Base)
      . /etc/lsb-release
      echo "Distribution: $DISTRIB_ID"
      echo "Version: $DISTRIB_RELEASE"
  elif [ -f /etc/debian_version ]; then
      # For Debian-based distributions without os-release or lsb-release
      echo "Distribution: Debian"
      echo "Version: $(cat /etc/debian_version)"
  elif [ -f /etc/redhat-release ]; then
      # For Red Hat-based distributions
      echo "Distribution: $(cat /etc/redhat-release)"
  elif [ -n "${OSTYPE+x}" ]; then
    if [ "${OSTYPE#darwin}" != "$OSTYPE" ]; then
        # macOS detection
        echo "Distribution: macOS"
        echo "Version: $(sw_vers -productVersion)"
    elif [ "$OSTYPE" = "cygwin" ] || [ "$OSTYPE" = "msys" ] || [ "$OSTYPE" = "win32" ]; then
        # Windows detection in environments like Git Bash, Cygwin, or MinGW
        echo "Distribution: Windows"
        echo "Version: $(cmd.exe /c ver | tr -d '\r')"
    elif [ "$OSTYPE" = "linux-gnu" ] && uname -r | grep -q "Microsoft"; then
        # Windows Subsystem for Linux (WSL) detection
        echo "Distribution: Windows (WSL)"
        echo "Version: $(uname -r)"
    fi
  else
      echo "Unknown operating system"
  fi
  if [ -f /proc/version ]; then
    # Check if running on WSL2 or WSL1 for Microsoft
    if grep -q "WSL2" /proc/version; then
      echo "Running on WSL2"
    elif grep -q "microsoft" /proc/version; then
      echo "Running on WSL1"
    fi
  fi
}

# Generate the error log
# parameter 1: error message
# parameter 2: the container names to retrieve, separated by comma
generate_error_log() {
  msg="$1"
  services="$2"

  error_file="$script_dir/$error_log"

  if [ -n "${msg}" ]; then
    echo "${msg}" > "$error_file"
  fi

  { 
    echo "Start-local version: ${version}"
    echo "$container_cli engine version: $container_runtime_version"
    echo "Elastic Stack version: ${es_version}"
    if [ "$esonly" = "true" ]; then
      echo "--esonly parameter used"
    fi
    if [ "$edot" = "true" ]; then
      echo "--edot parameter used"
    fi
    get_os_info
  } >> "$error_file"

  for service in $services; do
    echo "-- Logs of service ${service}:" >> "$error_file"
    $container_cli logs "${service}" >> "$error_file" 2> /dev/null
  done

  echo "An error log has been generated in '${error_log}' file."
  echo "If you need assistance, open an issue at https://github.com/elastic/start-local/issues"
}

### Main functions #################################################################################

startup() {
  echo
  echo '  ______ _           _   _      '
  echo ' |  ____| |         | | (_)     '
  echo ' | |__  | | __ _ ___| |_ _  ___ '
  echo ' |  __| | |/ _` / __| __| |/ __|'
  echo ' | |____| | (_| \__ \ |_| | (__ '
  echo ' |______|_|\__,_|___/\__|_|\___|'
  echo '-------------------------------------------------'
  echo '🚀 Run Elasticsearch and Kibana for local testing'
  echo '-------------------------------------------------'
  echo 
  echo 'ℹ️  Do not use this script in a production environment'
  echo

  # Version
  version="0.13.0"

  # Folder name for the installation
  installation_folder="${ES_LOCAL_DIR:-"$script_dir/elastic-start-local"}"
  # API key name for Elasticsearch
  api_key_name="elastic-start-local"
  # Name of the error log
  error_log="error-start-local.log"
  container_network_name="es-local-dev-net${ES_LOCAL_DIR:+-${ES_LOCAL_DIR}}"
  # Elasticsearch container name
  elasticsearch_container_name="es-local-dev${ES_LOCAL_DIR:+-${ES_LOCAL_DIR}}"
  # Kibana container name
  kibana_container_name="kibana-local-dev${ES_LOCAL_DIR:+-${ES_LOCAL_DIR}}"
  # EDOT container name
  edot_container_name="edot-collector${ES_LOCAL_DIR:+-${ES_LOCAL_DIR}}"
  # Minimum disk space required for docker images + services (in GB)
  min_disk_space_required=5

  # TODO:
  container_runtime_version=0.0.0
}

parse_args() {
  # Parameters
  esonly=false
  edot=false

  # Parse the script parameters.
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -v)
        # Check that there is another argument for the version.
        if [ $# -lt 2 ]; then
          echo "Error: -v requires a version value (eg. -v 8.17.0)"
          exit 1
        fi
        es_version="$2"
        shift 2
        ;;

      --esonly)
        esonly=true
        shift
        ;;

      --edot)
        edot=true
        shift
        ;;

      --)
        # End of options; shift and exit the loop.
        shift
        break
        ;;

      -*)
        # Unknown or unsupported option.
        echo "Error: Unknown option '$1'"
        exit 1
        ;;

      *)
        # We've hit a non-option argument; stop parsing options.
        break
        ;;
    esac
  done

  # Verify parameter consistency.
  if [ "$esonly" = "true" ] && [ "$edot" = "true" ]; then
    echo "Error: The --edot parameter requires also Kibana, you cannot use --esonly."
    exit 1
  fi
}

check_requirements() {
  # Check required commands.

  requirements='
curl|https://curl.se/download.html
grep|https://www.gnu.org/software/grep/
head|https://www.gnu.org/software/coreutils/
tail|https://www.gnu.org/software/coreutils/
tr|https://www.gnu.org/software/coreutils/
mkdir|https://www.gnu.org/software/coreutils/
uname|https://www.gnu.org/software/coreutils/
df|https://www.gnu.org/software/coreutils/
awk|https://www.gnu.org/software/gawk/
date|https://www.gnu.org/software/coreutils/
cat|https://www.gnu.org/software/coreutils/
'

  missing=0

  while IFS= read -r entry; do
    case "$entry" in
      ''|\#*) continue ;;
    esac

    case "$entry" in
      *'|'*)
        cmd=${entry%%|*}
        url=${entry#*|}
        ;;
      *)
        cmd=$entry
        url=
        ;;
    esac

    if ! available "$cmd"; then
      printf 'Error: %s command is required\n' "$cmd"
      if [ -n "$url" ]; then
        printf 'You can install it from %s\n' "$url"
      fi
      missing=1
    fi
  done <<EOF
$requirements
EOF

  if [ "$missing" -ne 0 ]; then
    exit 1
  fi

  # Check available disk space.

  check_disk_space_gb ${min_disk_space_required}
}

initialize_container_runtime() {
  # For development purposes, allow to force Docker even in this script.
  allow_docker=false

  available "docker" && has_docker=true || has_docker=false
  available "podman" && has_podman=true || has_podman=false

  if [ "$allow_docker" = "false" ] && [ "$has_podman" = "false" ]; then
    echo "Error: Podman is not installed."
    echo "You can install Podman from https://podman.io/getting-started/installation/."
    exit 1
  fi

  if [ "$has_docker" = "false" ] && [ "$has_podman" = "false" ]; then
    echo "Error: Either Docker or Podman must be installed."
    echo "You can install Docker from https://docs.docker.com/engine/install/."
    echo "You can install Podman from https://podman.io/getting-started/installation/."
    exit 1
  fi

  if [ "$has_docker" = "true" ]; then
    container_cli="docker"
    return 0
  fi

  container_cli="podman"
}

check_installation_folder() {
  # Check if $installation_folder exists
  folder=$installation_folder
  if [ -d "$folder" ]; then
    if [ -n "$(ls -A "$folder")" ]; then
      echo "It seems you already have a 'start-local' installation in '${folder}'."
      if [ -f "$folder/uninstall.sh" ]; then
        echo "I cannot proceed unless you uninstall it, using the following command:"
        echo "$folder/uninstall.sh"
      else
        echo "I did not find the 'uninstall.sh' file, you need to proceed manually."
        if [ -f "$folder/.env" ]; then
          echo "Execute the following commands:"
          # TODO:
        fi
      fi
      exit 1
    fi
  fi
}

check_container_services() {
  check_container_running "$elasticsearch_container_name"
  check_container_running "$kibana_container_name"
  check_container_running "$edot_container_name"
}

create_installation_folder() {
  if [ ! -d "$folder" ]; then 
    mkdir "$folder"
  fi
  cd "$folder"
}

generate_passwords() {
  # Generate random passwords.
  es_password="${ES_LOCAL_PASSWORD:-$(random_password)}"
  if [ "$esonly" = "false" ]; then
    kibana_password="$(random_password)"
    kibana_encryption_key="$(random_password 32)"
  fi
}

create_scripts() {
  write_up_script
  write_start_script
  write_stop_script
  write_down_script
  write_uninstall_script
}

choose_es_version() {
  if [ -z "${es_version:-}" ]; then
    # Get the latest Elasticsearch version
    es_version="$(get_latest_version)"
  fi
  # Fix for ARM64: add suffix "-arm64"
  if is_arm64 && [ "${es_version##*-arm64}" = "$es_version" ]; then
    es_version="${es_version}-arm64"
  fi
}

create_env_file() {
  today=$(date +%s)
  license_expire=$((today + 3600*24*30))

  # Create the .env file
  cat > .env <<- EOM
START_LOCAL_VERSION=$version
CONTAINER_CLI=$container_cli
CONTAINER_NETWORK_NAME=$container_network_name
ES_LOCAL_VERSION=$es_version
ES_LOCAL_CONTAINER_NAME=$elasticsearch_container_name
ES_LOCAL_PASSWORD=$es_password
ES_LOCAL_PORT=9200
ES_LOCAL_URL=http://localhost:\${ES_LOCAL_PORT}
ES_LOCAL_API_KEY_NAME=$api_key_name
ES_LOCAL_DISK_SPACE_REQUIRED=1gb
ES_LOCAL_LICENSE_EXPIRE_DATE=$license_expire
EOM

  if [ "$edot" = "true" ]; then
    cat >> .env <<- EOM
ES_LOCAL_JAVA_OPTS="-Xms2g -Xmx2g"
EDOT_LOCAL_CONTAINER_NAME=$edot_container_name
EOM
  else
    cat >> .env <<- EOM
ES_LOCAL_JAVA_OPTS="-Xms128m -Xmx2g"
EOM
  fi

  if [ "$esonly" = "false" ]; then
    cat >> .env <<- EOM
KIBANA_LOCAL_CONTAINER_NAME=$kibana_container_name
KIBANA_LOCAL_PORT=5601
KIBANA_LOCAL_PASSWORD=$kibana_password
KIBANA_ENCRYPTION_KEY=$kibana_encryption_key
EOM
  fi
}

create_kibana_config() {
  if [ "$esonly" = "true" ]; then
    return 0
  fi
   
  if [ ! -d "config" ]; then
    mkdir config
  fi

  # Create telemetry
  cat > config/telemetry.yml <<- EOM
start-local:
  version: ${version}
EOM
}

create_edot_config() {
  if [ "$edot" = "false" ]; then
    return 0
  fi

  if [ ! -d "$installation_folder/config/edot-collector" ]; then
    mkdir -p "$installation_folder/config/edot-collector"
  fi

  trace_processor_name="elasticapm"
  if [ "$(compare_versions "$es_version" "9.2.0")" = "lt" ];then
    trace_processor_name="elastictrace"
  fi
  # shellcheck disable=SC2016
  es_local_apikey_var='${ES_LOCAL_API_KEY}'
  cat > "$installation_folder/config/edot-collector/config.yaml" <<EOM
extensions:
  apmconfig:
    source:
      elasticsearch:
        endpoint: http://elastic:${es_password}@elasticsearch:9200
        cache_duration: 10s
    opamp:
      protocols:
        http:
          endpoint: 0.0.0.0:4320
receivers:
  # Receives data from other Collectors in Agent mode
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317 # Listen on all interfaces
      http:
        endpoint: 0.0.0.0:4318 # Listen on all interfaces

connectors:
  elasticapm: {} # Elastic APM Connector

processors:
  batch:
    send_batch_size: 1000
    timeout: 1s
    send_batch_max_size: 1500
  batch/metrics:
    send_batch_max_size: 0 # Explicitly set to 0 to avoid splitting metrics requests
    timeout: 1s
  ${trace_processor_name}: {}

exporters:
  debug: {}
  elasticsearch/otel:
    endpoints:
      - http://elasticsearch:9200
    api_key: ${es_local_apikey_var}
    tls:
      insecure_skip_verify: true
    mapping:
      mode: otel

service:
  extensions: [ apmconfig ]
  pipelines:
    metrics:
      receivers: [otlp]
      processors: [batch/metrics]
      exporters: [debug, elasticsearch/otel]
    logs:
      receivers: [otlp]
      processors: [batch]
      exporters: [debug, elasticapm, elasticsearch/otel]
    traces:
      receivers: [otlp]
      processors: [batch, ${trace_processor_name}]
      exporters: [debug, elasticapm, elasticsearch/otel]
    metrics/aggregated-otel-metrics:
      receivers:
        - elasticapm
      processors: [] # No processors defined in the original for this pipeline
      exporters:
        - debug
        - elasticsearch/otel
EOM
}

# --- Inline script writers -----------------------------------------------------------------------

write_up_script() {
  cat > ./up.sh <<'EOM'
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
  if [ "${CONTAINER_CLI}" != "podman" ] && ! detect_lxc >/dev/null 2>&1; then
    ulimit_args="--ulimit memlock=-1:-1"
  fi

  # Create container.
  # shellcheck disable=SC2086
  if ! output=$("$CONTAINER_CLI" create \
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
    "${image}" 2>&1); then
    echo "failed."
    printf '%s\n' "$output"
    return 1
  fi

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
  if ! output=$("$CONTAINER_CLI" create \
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
    "${image}" 2>&1); then
    echo "failed."
    printf '%s\n' "$output"
    return 1
  fi

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
  if ! output=$("$CONTAINER_CLI" create \
    --name "${EDOT_LOCAL_CONTAINER_NAME}" \
    --network "${CONTAINER_NETWORK_NAME}" \
    --hostname edot-collector \
    --network-alias edot-collector \
    -p "4317:4317" \
    -p "4318:4318" \
    -p "4320:4320" \
    -v "${edot_config_host_path}:/etc/otelcol-contrib/config.yaml:ro" \
    --env-file "$script_dir/.env" \
    "${image}" \
    --config=/etc/otelcol-contrib/config.yaml 2>&1); then
    echo "failed."
    printf '%s\n' "$output"
    return 1
  fi

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
EOM
  chmod +x ./up.sh
}

write_start_script() {
  cat > ./start.sh <<'EOM'
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

wait_for_healthcheck() {
  # wait_for_healthcheck <container-name> <check-cmd>
  name=${1:?name required}
  shift
  check_cmd="$*"
  timeout_seconds=${HEALTHCHECK_TIMEOUT:-300}
  delay_seconds=${HEALTHCHECK_DELAY:-10}

  start_time=$(date +%s)
  # shellcheck disable=SC2059
  printf "Waiting for '${name}' ... "
  while :; do
    # Execute the check command inside the container; it should return 0 on success.
    if $CONTAINER_CLI exec "${name}" sh -c "$check_cmd" >/dev/null 2>&1 ; then
      echo "healthy."
      return 0
    fi
    now=$(date +%s)
    if [ $((now - start_time)) -ge "${timeout_seconds}" ]; then
      echo "timed out."
      return 1
    fi
    sleep "${delay_seconds}"
  done
}

start_container() {
  # start_container <container-name>
  cname=${1:?container name required}

  # shellcheck disable=SC2059
  printf "Starting container '${cname}' ... "

  if ! $CONTAINER_CLI inspect "${cname}" >/dev/null 2>&1; then
    echo "failed (does not exist)."
    return 1
  fi

  if $CONTAINER_CLI ps --format '{{.Names}}' 2>/dev/null | grep -qxF "${cname}"; then
    echo "done (already running)."
    return 0
  fi

  if ! output=$("$CONTAINER_CLI" start "${cname}" 2>&1); then
    echo "failed."
    printf '%s\n' "$output"
    return 1
  fi

  echo "done."
  return 0
}

configure_kibana_system_user_password() {
  printf "Setting up 'kibana_system' user password ... "

  start_time=$(date +%s)
  timeout_seconds=60

  until \
    curl \
      -s \
      -X POST \
      "${ES_LOCAL_URL}/_security/user/kibana_system/_password" \
      -d "{\"password\":\"${KIBANA_LOCAL_PASSWORD}\"}" \
      -H "Authorization: ApiKey ${ES_LOCAL_API_KEY}" \
      -H "Content-Type: application/json" \
      | grep -q "^{}"; \
    do

    now=$(date +%s)
    if [ $((now - start_time)) -ge "${timeout_seconds}" ]; then
      printf "\n"
      echo "timed out.";
      exit 1
    fi

    sleep 2
  done

  echo "done."
}

create_elasticsearch_api_key() {
  printf "Creating Elasticsearch API key ... "

  status=0
  response=$(curl \
    -s \
    --fail \
    -u "elastic:${ES_LOCAL_PASSWORD}" \
    -X POST \
    "${ES_LOCAL_URL}/_security/api_key" \
    -d "{\"name\": \"${ES_LOCAL_API_KEY_NAME}\"}" \
    -H "Content-Type: application/json" \
  ) || status=$?

  if [ $status -ne 0 ]; then
    echo "failed."
    printf '%s\n' "$response"
    return 1
  fi

  ES_LOCAL_API_KEY="$(echo "$response" | grep -Eo '"encoded":"[A-Za-z0-9+/=]+' | grep -Eo '[A-Za-z0-9+/=]+' | tail -n 1)"
  echo "ES_LOCAL_API_KEY=${ES_LOCAL_API_KEY}" >> "$script_dir/.env"

  echo "done."
}

check_license() {
  today=$(date +%s)

  if [ -z "${ES_LOCAL_LICENSE:-}" ] && [ "$today" -gt "$ES_LOCAL_LICENSE_EXPIRE_DATE" ]; then
    echo "---------------------------------------------------------------------"
    echo "The one-month trial period has expired. You can continue using the"
    echo "Free and open Basic license or request to extend the trial for"
    echo "another 30 days using this form:"
    echo "https://www.elastic.co/trialextension"
    echo "---------------------------------------------------------------------"
    echo "For more info about the license: https://www.elastic.co/subscriptions"
    echo
    echo "Updating the license..."

    status=$(curl \
      -s \
      -X POST \
      "${ES_LOCAL_URL}/_license/start_basic?acknowledge=true" \
      -H "Authorization: ApiKey ${ES_LOCAL_API_KEY}" \
      -o /dev/null \
      -w '%{http_code}\n' \
    )

    if [ "$status" = "200" ]; then
      echo "✅ Basic license successfully installed"
      echo "ES_LOCAL_LICENSE=basic" >> .env
    else 
      echo "Error: Failed to activate Basic license (HTTP status code $status)."
      exit 1
    fi

    echo
  fi
}

main() {
  # Check disk space
  available_gb=$(($(df -k / | awk 'NR==2 {print $4}') / 1024 / 1024))
  required=$(echo "${ES_LOCAL_DISK_SPACE_REQUIRED}" | grep -Eo '[0-9]+')
  if [ "$available_gb" -lt "$required" ]; then
    echo "----------------------------------------------------------------------------"
    echo "WARNING: Disk space is below the ${required} GB limit. Elasticsearch will be"
    echo "executed in read-only mode. Please free up disk space to resolve this issue."
    echo "----------------------------------------------------------------------------"
    echo "Press ENTER to confirm."
    # shellcheck disable=SC2034
    read -r line
  fi

  HEALTHCHECK_TIMEOUT=${HEALTHCHECK_TIMEOUT:-300}
  HEALTHCHECK_DELAY=${HEALTHCHECK_DELAY:-10}

  # Start Elasticsearch and wait for it to respond to REST requests.
  start_container "${ES_LOCAL_CONTAINER_NAME}" || exit 1
  es_check="curl --output /dev/null --silent --head --fail -u elastic:${ES_LOCAL_PASSWORD} http://elasticsearch:9200"
  wait_for_healthcheck "${ES_LOCAL_CONTAINER_NAME}" "$es_check" || exit 1

  # Create Elasticsearch API key for local use on first start.
  if [ -z "${ES_LOCAL_API_KEY:-}" ]; then
    create_elasticsearch_api_key
  fi

  check_license

  if [ -n "${KIBANA_LOCAL_CONTAINER_NAME:-}" ]; then
    # Configure Kibana system_user password before starting Kibana.
    configure_kibana_system_user_password

    # Start Kibana and wait for it to respond to REST requests.
    start_container "${KIBANA_LOCAL_CONTAINER_NAME}" || exit 1
    kibana_check="curl -s -I http://kibana:5601 | grep -q 'HTTP/1.1 302 Found'"
    wait_for_healthcheck "${KIBANA_LOCAL_CONTAINER_NAME}" "$kibana_check" || exit 1
  fi

  if [ -n "${EDOT_LOCAL_CONTAINER_NAME:-}" ]; then
    # Start edot-collector and wait for it to respond to requests.
    start_container "${EDOT_LOCAL_CONTAINER_NAME}" || exit 1
    edot_check="echo -n > /dev/tcp/127.0.0.1/4317"
    wait_for_healthcheck "${EDOT_LOCAL_CONTAINER_NAME}" "$edot_check" || exit 1
  fi
}

main
EOM
  chmod +x ./start.sh
}

write_stop_script() {
  cat > ./stop.sh <<'EOM'
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

stop_container() {
  # stop_container <container-name>
  name=${1:?container name required}

  # shellcheck disable=SC2059
  printf "Stopping container '$name' ... "

  # If container doesn't exist, nothing to do.
  if ! "$CONTAINER_CLI" inspect "$name" >/dev/null 2>&1; then
    echo "done (does not exist)."
    return 0
  fi

  # Try graceful stop (ignore errors if not running).
  if "$CONTAINER_CLI" stop "$name" >/dev/null 2>&1; then
    echo "done (stopped)."
    return 0
  fi

  # Force stop.
  if "$CONTAINER_CLI" kill "$name" >/dev/null 2>&1; then
    echo "done (killed)."
    return 0
  fi

  echo "failed."
  return 1
}

stop_elasticsearch_container() {
  [ -n "${ES_LOCAL_CONTAINER_NAME:-}" ] || { echo "ES_LOCAL_CONTAINER_NAME not set"; return 1; }

  stop_container "${ES_LOCAL_CONTAINER_NAME}"
}

stop_kibana_container() {
  [ -n "${KIBANA_LOCAL_CONTAINER_NAME:-}" ] || { echo "KIBANA_LOCAL_CONTAINER_NAME not set"; return 1; }

  stop_container "${KIBANA_LOCAL_CONTAINER_NAME}"
}

stop_edot_container() {
  [ -n "${EDOT_LOCAL_CONTAINER_NAME:-}" ] || { echo "EDOT_LOCAL_CONTAINER_NAME not set"; return 1; }

  stop_container "${EDOT_LOCAL_CONTAINER_NAME}"
}

main() {
  if [ -n "${EDOT_LOCAL_CONTAINER_NAME:-}" ]; then
    stop_edot_container
  fi

  if [ -n "${KIBANA_LOCAL_CONTAINER_NAME:-}" ]; then
    stop_kibana_container
  fi

  stop_elasticsearch_container
}

main
EOM
  chmod +x ./stop.sh
}

write_down_script() {
  cat > ./down.sh <<'EOM'
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

remove_bridged_network() {
  [ -n "${CONTAINER_NETWORK_NAME:-}" ] || { echo "CONTAINER_NETWORK_NAME not set"; return 1; }

  # shellcheck disable=SC2059
  printf "Removing network '${CONTAINER_NETWORK_NAME}' ... "

  if ! "$CONTAINER_CLI" network inspect "${CONTAINER_NETWORK_NAME}" >/dev/null 2>&1; then
    echo "done (does not exist)."
    return 0
  fi

  # Try graceful removal the network; if it's in use this will typically fail.
  "$CONTAINER_CLI" network rm "${CONTAINER_NETWORK_NAME}" >/dev/null 2>&1 || true

  # Force remove.
  if "$CONTAINER_CLI" network rm -f "${CONTAINER_NETWORK_NAME}" >/dev/null 2>&1; then
    echo "done (removed)."
    return 0
  fi

  echo "failed."

  return 1
}

remove_volume() {
  # remove_volumes <volume>
  [ -n "${1:-}" ] || { echo "Usage: remove_volume <volume-name>"; return 1; }

  vol="$1"

  # shellcheck disable=SC2059
  printf "Removing volume '$vol' ... "

  if ! "$CONTAINER_CLI" volume inspect "$vol" >/dev/null 2>&1; then
    echo "done (does not exist)."
    return 0
  fi

  if "$CONTAINER_CLI" volume rm -f "$vol" >/dev/null 2>&1; then
    echo "done (removed)."
    return 0
  fi

  echo "failed."

  # If removal failed, attempt to list attached containers to help the user.
  echo "Volume '${vol}' may be in use."
  echo "Attached containers (if any):"
  "$CONTAINER_CLI" volume inspect "${vol}" 2>/dev/null || true
  echo "Disconnect or stop containers and retry: '${CONTAINER_CLI} volume rm -f ${vol}'"

  return 1
}

remove_container() {
  # remove_container <container-name>
  name=${1:?container name required}

  # shellcheck disable=SC2059
  printf "Removing container '$name' ... "

  # If container doesn't exist, nothing to do.
  if ! "$CONTAINER_CLI" inspect "$name" >/dev/null 2>&1; then
    echo "done (does not exist)."
    return 0
  fi

  # Try graceful stop (ignore errors if not running).
  "$CONTAINER_CLI" stop "$name" >/dev/null 2>&1 || true

  # Force remove (will stop if still running).
  if "$CONTAINER_CLI" rm -f "$name" >/dev/null 2>&1; then
    echo "done (removed)."
    return 0
  fi

  echo "failed."
  return 1
}

remove_elasticsearch_container() {
  [ -n "${ES_LOCAL_CONTAINER_NAME:-}" ] || { echo "ES_LOCAL_CONTAINER_NAME not set"; return 1; }

  remove_container "${ES_LOCAL_CONTAINER_NAME}"
  remove_volume dev-elasticsearch
}

remove_kibana_container() {
  [ -n "${KIBANA_LOCAL_CONTAINER_NAME:-}" ] || { echo "KIBANA_LOCAL_CONTAINER_NAME not set"; return 1; }

  remove_container "${KIBANA_LOCAL_CONTAINER_NAME}"
  remove_volume dev-kibana
}

remove_edot_container() {
  [ -n "${EDOT_LOCAL_CONTAINER_NAME:-}" ] || { echo "EDOT_LOCAL_CONTAINER_NAME not set"; return 1; }

  remove_container "${EDOT_LOCAL_CONTAINER_NAME}"
}

main() {
  if [ -n "${EDOT_LOCAL_CONTAINER_NAME:-}" ]; then
    remove_edot_container
  fi

  if [ -n "${KIBANA_LOCAL_CONTAINER_NAME:-}" ]; then
    remove_kibana_container
  fi

  remove_elasticsearch_container
  remove_bridged_network
}

main
EOM
  chmod +x ./down.sh
}

write_uninstall_script() {
  cat > ./uninstall.sh <<'EOM'
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

ask_confirmation() {
  echo "Do you confirm? (yes/no)"
  read -r answer
  case "$answer" in
    yes|y|Y|Yes|YES)
      return 0  # true
      ;;
    no|n|N|No|NO)
      return 1  # false
      ;;
    *)
      echo "Please answer yes or no."
      ask_confirmation  # Ask again if the input is invalid
      ;;
  esac
}

main() {
  if [ ! -e "$script_dir/.env" ]; then
    echo "Error: I cannot find the .env file."
    echo "I cannot uninstall start-local."
  fi

  # shellcheck disable=SC1091
  . "$script_dir/.env"

  [ -n "${CONTAINER_CLI:-}" ] || { echo "CONTAINER_CLI not set"; exit 1; }
  command -v "$CONTAINER_CLI" >/dev/null 2>&1 || { echo "Error: '$CONTAINER_CLI' not found."; exit 1; }

  echo "This script will uninstall start-local."
  echo "All data will be deleted and cannot be recovered."

  if ! ask_confirmation; then
    return 0
  fi

  # TODO: Embed down.sh content here to avoid sourcing external script.
  "$script_dir/down.sh" || true

  rm -f "$script_dir/.env"
  rm -f "$script_dir/up.sh"
  rm -f "$script_dir/down.sh"
  rm -f "$script_dir/start.sh"
  rm -f "$script_dir/stop.sh"
  rm -f "$script_dir/uninstall.sh"
  rm -rf "$script_dir/config"

  echo
  echo "Do you want to remove the following images?"
  echo "- docker.elastic.co/elasticsearch/elasticsearch:${ES_LOCAL_VERSION}"

  if [ -n "${KIBANA_LOCAL_CONTAINER_NAME:-}" ]; then
    echo "- docker.elastic.co/kibana/kibana:${ES_LOCAL_VERSION}"
  fi

  if [ -n "${EDOT_LOCAL_CONTAINER_NAME:-}" ]; then
    echo "- docker.elastic.co/elastic-agent/elastic-edot-collector:${ES_LOCAL_VERSION}"
  fi

  if ! ask_confirmation; then
    echo "Elastic start-local successfully removed."
    return 0
  fi

  $CONTAINER_CLI rmi "docker.elastic.co/elasticsearch/elasticsearch:${ES_LOCAL_VERSION}" >/dev/null 2>&1 || \
    echo "Failed to remove 'docker.elastic.co/elasticsearch/elasticsearch' image."

  if [ -n "${KIBANA_LOCAL_CONTAINER_NAME:-}" ]; then
    $CONTAINER_CLI rmi "docker.elastic.co/kibana/kibana:${ES_LOCAL_VERSION}" >/dev/null 2>&1 || \
      echo "Failed to remove 'docker.elastic.co/kibana/kibana' image."
  fi

  if [ -n "${EDOT_LOCAL_CONTAINER_NAME:-}" ]; then
    $CONTAINER_CLI rmi "docker.elastic.co/elastic-agent/elastic-otel-collector:${ES_LOCAL_VERSION}" >/dev/null 2>&1 || \
      echo "Failed to remove 'docker.elastic.co/elastic-agent/elastic-otel-collector' image."
  fi

  echo "Elastic start-local successfully removed."
}

main
EOM
  chmod +x ./uninstall.sh
}

print_steps() {
  if  [ "$esonly" = "true" ]; then
    echo "⌛️ Setting up Elasticsearch v${es_version}..."
  elif [ "$edot" = "true" ]; then
    echo "⌛️ Setting up Elasticsearch, Kibana and EDOT collector v${es_version}..."
  else
    echo "⌛️ Setting up Elasticsearch and Kibana v${es_version}..."
  fi
  echo
  echo "- Generated random passwords"
  echo "- Created the ${folder} folder containing the files:"
  echo "  - .env, with settings"
  echo "  - configuration files for Kibana and EDOT (if selected)"
  echo "  - start/stop/uninstall commands"
}

initialize_containers() {
  # Execute docker compose
  echo "- Initializing and starting containers..."
  echo

  if ( set +e; ./up.sh && ./start.sh ); then
    return 0
  fi

  error_msg="Error: Container initialization failed!"
  echo "$error_msg"
  if [ "$esonly" = "true" ]; then
    generate_error_log "${error_msg}" "${elasticsearch_container_name}"
  elif [ "$edot" = "true" ]; then
    generate_error_log "${error_msg}" "${elasticsearch_container_name} ${kibana_container_name} ${edot_container_name}"
  else
    generate_error_log "${error_msg}" "${elasticsearch_container_name} ${kibana_container_name}"
  fi

  cleanup
  exit 1
}

success() {
  echo
  if  [ "$esonly" = "true" ]; then
    echo "🎉 Congrats, Elasticsearch is installed and running!"
  else
    if [ "$edot" = "true" ]; then
      echo "🎉 Congrats, Elasticsearch, Kibana and EDOT collector are installed and running!"
    else
      echo "🎉 Congrats, Elasticsearch and Kibana are installed and running!"
    fi
    echo
    echo "🌐 Open your browser at http://localhost:5601"
    echo
    echo "   Username: elastic"
    echo "   Password: ${es_password}"
    echo
  fi

  echo "🔌 Elasticsearch API endpoint: http://localhost:9200"
  if [ "$edot" = "true" ]; then
    echo "🔭 OTLP endpoints: gRPC http://localhost:4317 and HTTP http://localhost:4318"
    echo "🔭 OpAMP endpoint: http://localhost:4320/v1/opamp"
  fi

  # Load ES_LOCAL_API_KEY environment variable.
  . "$installation_folder/.env"

  if [ -n "$ES_LOCAL_API_KEY" ]; then
    echo "🔑 API key: $ES_LOCAL_API_KEY"
    echo
  else
    echo "🔑 Use basic auth or create an API key"
    echo "https://www.elastic.co/guide/en/kibana/current/api-keys.html"
    echo
  fi
  echo "Learn more at https://github.com/elastic/start-local"
  echo
}

main() {
  startup
  parse_args "$@"
  check_requirements
  initialize_container_runtime
  check_installation_folder
  check_container_services
  create_installation_folder
  generate_passwords
  choose_es_version
  create_scripts
  create_env_file
  create_kibana_config
  create_edot_config
  print_steps
  initialize_containers
  success
}

ctrl_c() {
  cleanup
  exit 1
}

### Script execution ###############################################################################

# Trap SGIINT and call ctrl_c().
trap ctrl_c INT

# Execute the entry point function.
main "$@"

####################################################################################################
