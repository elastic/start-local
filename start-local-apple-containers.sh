#!/bin/sh
# --------------------------------------------------------
# Run Elasticsearch and Kibana for local testing
# using Apple containers (https://github.com/apple/container)
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
#
# Notes about Apple containers (the `container` CLI):
# - There is no Compose equivalent: this script creates and orchestrates the
#   containers itself (like the Podman variant does).
# - Every container is a lightweight VM with its own IP address. Container
#   names/aliases are not resolvable by other containers unless a local DNS
#   domain is configured (that requires administrator rights), so Kibana and
#   the EDOT collector are pointed to the IP address of the Elasticsearch
#   container, which is detected every time the stack is started.
# - New volumes are owned by root, so they are prepared (chown) for the
#   user 1000 used by the Elastic images.

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

# Check if a container already exists (running or stopped)
# parameter: the name of the container
check_container_exists() {
  container_name=$1

  if "$container_cli" inspect "${container_name}" >/dev/null 2>&1; then
    echo "The container '$container_name' does already exist!"
    echo "To remove the container run the following command:"
    echo
    echo "$container_cli delete --force $container_name"
    exit 1
  fi
}

# Generates a random password with letters and numbers
# parameter: size of the password (default is 8 characters)
random_password() {
  LENGTH="${1:-8}"
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c "${LENGTH}"
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
  versions="$(curl -s "https://elastic-release-api.s3.us-west-2.amazonaws.com/public/past-releases.json")"
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
    if [ -f "$installation_folder/down.sh" ]; then
      "$installation_folder/stop.sh" >/dev/null 2>&1 || true
      "$installation_folder/down.sh" >/dev/null 2>&1 || true
    fi

    rm -rf "$installation_folder"
  fi
}

get_os_info() {
  echo "Distribution: macOS"
  echo "Version: $(sw_vers -productVersion 2>/dev/null || uname -r)"
  echo "Architecture: $(uname -m)"
}

# Generate the error log
# parameter 1: error message
# parameter 2: the container names to retrieve, separated by space
generate_error_log() {
  msg="$1"
  services="$2"

  error_file="$script_dir/$error_log"

  if [ -n "${msg}" ]; then
    echo "${msg}" > "$error_file"
  fi

  {
    echo "Start-local version: ${version}"
    echo "$container_cli CLI version: $container_runtime_version"
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
    $container_cli logs "${service}" >> "$error_file" 2> /dev/null || true
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
  version="0.14.0"

  # Folder name for the installation
  # (always an absolute path, because the script changes directory)
  case "${ES_LOCAL_DIR:-}" in
    "") installation_folder="$script_dir/elastic-start-local" ;;
    /*) installation_folder="$ES_LOCAL_DIR" ;;
    *) installation_folder="$PWD/$ES_LOCAL_DIR" ;;
  esac
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
  # Volume names
  elasticsearch_volume_name="dev-elasticsearch${ES_LOCAL_DIR:+-${ES_LOCAL_DIR}}"
  kibana_volume_name="dev-kibana${ES_LOCAL_DIR:+-${ES_LOCAL_DIR}}"
  # Minimum disk space required for container images + services (in GB)
  min_disk_space_required=5
  # Every Apple container is a VM with its own amount of memory (default is 1 GB)
  es_memory="${ES_LOCAL_MEMORY:-4g}"
  kibana_memory="${KIBANA_LOCAL_MEMORY:-3g}"
  edot_memory="${EDOT_LOCAL_MEMORY:-1g}"
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
  if [ "$(uname -s)" != "Darwin" ] || { [ "$(uname -m)" != "arm64" ] && [ "$(uname -m)" != "aarch64" ]; }; then
    echo "Error: Apple containers require a Mac with Apple silicon."
    echo "On other platforms you can use the Docker or Podman scripts instead:"
    echo
    echo "  curl -fsSL https://elastic.co/start-local | sh"
    exit 1
  fi

  if ! available "container"; then
    echo "Error: the Apple 'container' command is not installed."
    echo "You can install it from https://github.com/apple/container/releases"
    if available "docker" || available "podman"; then
      echo
      echo "Docker or Podman was detected, so you can use the other scripts instead:"
      echo
      echo "  curl -fsSL https://elastic.co/start-local | sh"
    fi
    exit 1
  fi
  container_cli="container"

  macos_major="$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)"
  if [ -n "$macos_major" ] && [ "$macos_major" -lt 26 ]; then
    echo "⚠️  Warning: Apple containers are designed for macOS 26 or later."
    echo "   On older versions the networking features needed by this script may not work."
    echo
  fi

  if ! "$container_cli" system status >/dev/null 2>&1; then
    echo "The Apple container services are not running."
    echo "Start them with the following command and run this script again:"
    echo
    echo "  container system start"
    exit 1
  fi

  container_runtime_version="$("$container_cli" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)"
  container_runtime_version="${container_runtime_version:-unknown}"
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
          echo "$folder/down.sh"
          echo "rm -rf $folder"
        fi
      fi
      exit 1
    fi
  fi
}

check_container_services() {
  check_container_exists "$elasticsearch_container_name"
  check_container_exists "$kibana_container_name"
  check_container_exists "$edot_container_name"
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
  write_common_script
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
  # Note: the Elastic images are multi-arch, so no "-arm64" suffix is needed.
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
ES_LOCAL_VOLUME_NAME=$elasticsearch_volume_name
ES_LOCAL_MEMORY=$es_memory
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
EDOT_LOCAL_MEMORY=$edot_memory
EOM
  else
    cat >> .env <<- EOM
ES_LOCAL_JAVA_OPTS="-Xms128m -Xmx2g"
EOM
  fi

  if [ "$esonly" = "false" ]; then
    cat >> .env <<- EOM
KIBANA_LOCAL_CONTAINER_NAME=$kibana_container_name
KIBANA_LOCAL_VOLUME_NAME=$kibana_volume_name
KIBANA_LOCAL_MEMORY=$kibana_memory
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
  # The variables are resolved by the collector from its environment,
  # see create_edot_container() in start.sh
  # shellcheck disable=SC2016
  es_local_password_var='${ES_LOCAL_PASSWORD}'
  # shellcheck disable=SC2016
  es_internal_host_var='${ES_INTERNAL_HOST}'
  cat > "$installation_folder/config/edot-collector/config.yaml" <<EOM
extensions:
  apmconfig:
    source:
      elasticsearch:
        endpoint: http://elastic:${es_local_password_var}@${es_internal_host_var}:9200
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
      - http://${es_internal_host_var}:9200
    user: elastic
    password: ${es_local_password_var}
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

# Print the header shared by all the generated scripts
script_header() {
  cat <<'EOM'
#!/bin/sh
# --------------------------------------------------------
# Run Elasticsearch and Kibana for local testing
# using Apple containers (https://github.com/apple/container)
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

EOM
}

# Functions shared by the generated scripts (sourced by up.sh, start.sh, stop.sh, down.sh)
write_common_script() {
  {
    script_header
    cat <<'EOM'
# This file is sourced by the other scripts, do not execute it directly.

# shellcheck disable=SC1091
. "$script_dir/.env"

[ -n "${CONTAINER_CLI:-}" ] || { echo "CONTAINER_CLI not set"; exit 1; }
command -v "$CONTAINER_CLI" >/dev/null 2>&1 || { echo "Error: '$CONTAINER_CLI' not found."; exit 1; }

if ! "$CONTAINER_CLI" system status >/dev/null 2>&1; then
  echo "The Apple container services are not running."
  echo "Start them with the following command and run this script again:"
  echo
  echo "  container system start"
  exit 1
fi

# Returns 0 if the container exists (running or stopped)
container_exists() {
  "$CONTAINER_CLI" inspect "$1" >/dev/null 2>&1
}

# Returns 0 if the container is running
container_running() {
  "$CONTAINER_CLI" inspect "$1" 2>/dev/null | grep -q '"state" *: *"running"'
}

# Prints the IPv4 address of a container (empty if not available)
container_ip() {
  "$CONTAINER_CLI" inspect "$1" 2>/dev/null \
    | grep -Eo '"ipv4Address" *: *"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
    | head -n 1 \
    | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true
}
EOM
  } > ./common.sh
}

write_up_script() {
  {
    script_header
    cat <<'EOM'
set -eu

script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$script_dir/common.sh"

create_network() {
  [ -n "${CONTAINER_NETWORK_NAME:-}" ] || { echo "CONTAINER_NETWORK_NAME not set"; return 1; }

  # shellcheck disable=SC2059
  printf "Creating network '$CONTAINER_NETWORK_NAME' ... "

  # If network already exists, nothing to do.
  if "$CONTAINER_CLI" network inspect "$CONTAINER_NETWORK_NAME" >/dev/null 2>&1; then
    echo "done (already exists)."
    return 0
  fi

  if output=$("$CONTAINER_CLI" network create "$CONTAINER_NETWORK_NAME" 2>&1); then
    echo "done (created)."
    return 0
  fi

  echo "failed."
  printf '%s\n' "$output"
  return 1
}

# Create a volume and give the ownership to the user of the Elastic images (uid 1000, gid 0).
# New volumes are owned by root and Elasticsearch/Kibana cannot write on them.
# parameter 1: volume name
# parameter 2: mount path inside the container
# parameter 3: image used to change the ownership
create_volume() {
  vol=${1:?volume name required}
  mount_path=${2:?mount path required}
  vol_image=${3:?image required}

  # shellcheck disable=SC2059
  printf "Creating volume '$vol' ... "

  if "$CONTAINER_CLI" volume inspect "$vol" >/dev/null 2>&1; then
    echo "done (already exists)."
    return 0
  fi

  if ! output=$("$CONTAINER_CLI" volume create "$vol" 2>&1); then
    echo "failed."
    printf '%s\n' "$output"
    return 1
  fi

  if ! output=$("$CONTAINER_CLI" run --rm --user 0 --entrypoint chown \
    -v "${vol}:${mount_path}" "$vol_image" -R 1000:0 "$mount_path" 2>&1); then
    echo "failed."
    printf '%s\n' "$output"
    return 1
  fi

  echo "done (created)."
  return 0
}

create_elasticsearch_container() {
  [ -n "${CONTAINER_NETWORK_NAME:-}" ] || { echo "CONTAINER_NETWORK_NAME not set"; return 1; }
  [ -n "${ES_LOCAL_VERSION:-}" ] || { echo "ES_LOCAL_VERSION not set"; return 1; }
  [ -n "${ES_LOCAL_CONTAINER_NAME:-}" ] || { echo "ES_LOCAL_CONTAINER_NAME not set"; return 1; }
  [ -n "${ES_LOCAL_VOLUME_NAME:-}" ] || { echo "ES_LOCAL_VOLUME_NAME not set"; return 1; }
  [ -n "${ES_LOCAL_PORT:-}" ] || { echo "ES_LOCAL_PORT not set"; return 1; }
  [ -n "${ES_LOCAL_PASSWORD:-}" ] || { echo "ES_LOCAL_PASSWORD not set"; return 1; }

  ES_LOCAL_JAVA_OPTS=${ES_LOCAL_JAVA_OPTS:-}
  ES_LOCAL_DISK_SPACE_REQUIRED=${ES_LOCAL_DISK_SPACE_REQUIRED:-85%}
  ES_LOCAL_MEMORY=${ES_LOCAL_MEMORY:-4g}

  image="docker.elastic.co/elasticsearch/elasticsearch:${ES_LOCAL_VERSION}"

  create_volume "${ES_LOCAL_VOLUME_NAME}" /usr/share/elasticsearch/data "${image}"

  # shellcheck disable=SC2059
  printf "Creating container '${ES_LOCAL_CONTAINER_NAME}' from image '${image}' ... "

  # If container exists, do nothing.
  if container_exists "${ES_LOCAL_CONTAINER_NAME}"; then
    echo "done (already exists)."
    return 0
  fi

  # Create container.
  # Note: _JAVA_OPTIONS is a fix for JDK AArch64 issue, see https://bugs.openjdk.org/browse/JDK-8345296
  if ! output=$("$CONTAINER_CLI" create \
    --name "${ES_LOCAL_CONTAINER_NAME}" \
    --network "${CONTAINER_NETWORK_NAME}" \
    --memory "${ES_LOCAL_MEMORY}" \
    --publish "127.0.0.1:${ES_LOCAL_PORT}:9200" \
    --volume "${ES_LOCAL_VOLUME_NAME}:/usr/share/elasticsearch/data" \
    --ulimit memlock=-1:-1 \
    -e "discovery.type=single-node" \
    -e "ELASTIC_PASSWORD=${ES_LOCAL_PASSWORD}" \
    -e "xpack.security.enabled=true" \
    -e "xpack.security.http.ssl.enabled=false" \
    -e "xpack.license.self_generated.type=trial" \
    -e "xpack.ml.use_auto_machine_memory_percent=true" \
    -e "ES_JAVA_OPTS=${ES_LOCAL_JAVA_OPTS}" \
    -e "_JAVA_OPTIONS=-XX:UseSVE=0" \
    -e "cluster.routing.allocation.disk.watermark.low=${ES_LOCAL_DISK_SPACE_REQUIRED}" \
    -e "cluster.routing.allocation.disk.watermark.high=${ES_LOCAL_DISK_SPACE_REQUIRED}" \
    -e "cluster.routing.allocation.disk.watermark.flood_stage=${ES_LOCAL_DISK_SPACE_REQUIRED}" \
    "${image}" 2>&1); then
    echo "failed."
    printf '%s\n' "$output"
    return 1
  fi

  echo "done (created)."
  return 0
}

# Kibana volume. The Kibana and EDOT containers are created by start.sh, because they need
# the IP address of the Elasticsearch container (container names are not resolvable).
create_kibana_volume() {
  [ -n "${KIBANA_LOCAL_VOLUME_NAME:-}" ] || { echo "KIBANA_LOCAL_VOLUME_NAME not set"; return 1; }
  create_volume "${KIBANA_LOCAL_VOLUME_NAME}" /usr/share/kibana/data "docker.elastic.co/kibana/kibana:${ES_LOCAL_VERSION}"
}

main() {
  create_network
  create_elasticsearch_container

  if [ -n "${KIBANA_LOCAL_CONTAINER_NAME:-}" ]; then
    create_kibana_volume
  fi
}

main
EOM
  } > ./up.sh
  chmod +x ./up.sh
}

write_start_script() {
  {
    script_header
    cat <<'EOM'
set -eu

script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$script_dir/common.sh"

# Wait until an HTTP endpoint answers with a successful check.
# parameter 1: description
# parameter 2: container name (to detect if it is not running anymore)
# parameter 3: the check command, executed on the host
wait_for_healthcheck() {
  name=${1:?name required}
  cname=${2:?container name required}
  shift 2
  check_cmd="$*"
  timeout_seconds=${HEALTHCHECK_TIMEOUT:-300}
  delay_seconds=${HEALTHCHECK_DELAY:-5}

  start_time=$(date +%s)
  # shellcheck disable=SC2059
  printf "Waiting for '${name}' ... "
  while :; do
    if sh -c "$check_cmd" >/dev/null 2>&1 ; then
      echo "healthy."
      return 0
    fi
    if ! container_running "${cname}"; then
      echo "failed (the container is not running)."
      return 1
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

  if ! container_exists "${cname}"; then
    echo "failed (does not exist)."
    return 1
  fi

  if container_running "${cname}"; then
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

# Remove a container, if it exists
remove_container() {
  cname=${1:?container name required}
  if container_exists "${cname}"; then
    "$CONTAINER_CLI" delete --force "${cname}" >/dev/null 2>&1 || true
  fi
}

# Wait for the IP address of the Elasticsearch container
get_elasticsearch_ip() {
  tries=0
  while [ "$tries" -lt 30 ]; do
    es_ip="$(container_ip "${ES_LOCAL_CONTAINER_NAME}")"
    if [ -n "$es_ip" ]; then
      return 0
    fi
    tries=$((tries + 1))
    sleep 1
  done
  echo "Error: cannot detect the IP address of '${ES_LOCAL_CONTAINER_NAME}'."
  return 1
}

# Kibana is (re)created at every start, because the IP address of Elasticsearch can change
create_kibana_container() {
  [ -n "${CONTAINER_NETWORK_NAME:-}" ] || { echo "CONTAINER_NETWORK_NAME not set"; return 1; }
  [ -n "${KIBANA_LOCAL_PORT:-}" ] || { echo "KIBANA_LOCAL_PORT not set"; return 1; }
  [ -n "${KIBANA_LOCAL_PASSWORD:-}" ] || { echo "KIBANA_LOCAL_PASSWORD not set"; return 1; }

  KIBANA_LOCAL_MEMORY=${KIBANA_LOCAL_MEMORY:-3g}
  telemetry_host_path="$script_dir/config/telemetry.yml"
  image="docker.elastic.co/kibana/kibana:${ES_LOCAL_VERSION}"

  # shellcheck disable=SC2059
  printf "Creating container '${KIBANA_LOCAL_CONTAINER_NAME}' from image '${image}' ... "

  remove_container "${KIBANA_LOCAL_CONTAINER_NAME}"

  if [ -f "${telemetry_host_path}" ]; then
    telemetry_mount="--volume ${telemetry_host_path}:/usr/share/kibana/config/telemetry.yml:ro"
  else
    telemetry_mount=""
  fi

  if [ -n "${EDOT_LOCAL_CONTAINER_NAME:-}" ]; then
    default_solution="oblt"
  else
    default_solution="es"
  fi

  # shellcheck disable=SC2086
  if ! output=$("$CONTAINER_CLI" create \
    --name "${KIBANA_LOCAL_CONTAINER_NAME}" \
    --network "${CONTAINER_NETWORK_NAME}" \
    --memory "${KIBANA_LOCAL_MEMORY}" \
    --publish "127.0.0.1:${KIBANA_LOCAL_PORT}:5601" \
    --volume "${KIBANA_LOCAL_VOLUME_NAME}:/usr/share/kibana/data" \
    $telemetry_mount \
    -e "SERVER_NAME=kibana" \
    -e "ELASTICSEARCH_HOSTS=http://${es_ip}:9200" \
    -e "ELASTICSEARCH_USERNAME=kibana_system" \
    -e "ELASTICSEARCH_PASSWORD=${KIBANA_LOCAL_PASSWORD}" \
    -e "XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY=${KIBANA_ENCRYPTION_KEY:-}" \
    -e "ELASTICSEARCH_PUBLICBASEURL=http://localhost:${ES_LOCAL_PORT}" \
    -e "MONITORING_UI_CONTAINER_ELASTICSEARCH_ENABLED=true" \
    -e "XPACK_SPACES_DEFAULTSOLUTION=${default_solution}" \
    "${image}" 2>&1); then
    echo "failed."
    printf '%s\n' "$output"
    return 1
  fi

  echo "done (created)."
  return 0
}

# The EDOT collector is (re)created at every start, because the IP address of Elasticsearch can change
create_edot_container() {
  [ -n "${CONTAINER_NETWORK_NAME:-}" ] || { echo "CONTAINER_NETWORK_NAME not set"; return 1; }

  EDOT_LOCAL_MEMORY=${EDOT_LOCAL_MEMORY:-1g}
  edot_config_host_path="$script_dir/config/edot-collector/config.yaml"
  image="docker.elastic.co/elastic-agent/elastic-otel-collector:${ES_LOCAL_VERSION}"

  # shellcheck disable=SC2059
  printf "Creating container '${EDOT_LOCAL_CONTAINER_NAME}' from image '${image}' ... "

  remove_container "${EDOT_LOCAL_CONTAINER_NAME}"

  if ! output=$("$CONTAINER_CLI" create \
    --name "${EDOT_LOCAL_CONTAINER_NAME}" \
    --network "${CONTAINER_NETWORK_NAME}" \
    --memory "${EDOT_LOCAL_MEMORY}" \
    --publish "4317:4317" \
    --publish "4318:4318" \
    --publish "4320:4320" \
    --volume "${edot_config_host_path}:/etc/otelcol-contrib/config.yaml:ro" \
    -e "ES_LOCAL_PASSWORD=${ES_LOCAL_PASSWORD}" \
    -e "ES_INTERNAL_HOST=${es_ip}" \
    "${image}" \
    --config=/etc/otelcol-contrib/config.yaml 2>&1); then
    echo "failed."
    printf '%s\n' "$output"
    return 1
  fi

  echo "done (created)."
  return 0
}

configure_kibana_system_user_password() {
  printf "Setting up 'kibana_system' user password ... "

  start_time=$(date +%s)
  timeout_seconds=60

  until \
    curl \
      --noproxy '*' \
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
    --noproxy '*' \
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
      --noproxy '*' \
      -s \
      -X POST \
      "${ES_LOCAL_URL}/_license/start_basic?acknowledge=true" \
      -H "Authorization: ApiKey ${ES_LOCAL_API_KEY}" \
      -o /dev/null \
      -w '%{http_code}\n' \
    )

    if [ "$status" = "200" ]; then
      echo "✅ Basic license successfully installed"
      echo "ES_LOCAL_LICENSE=basic" >> "$script_dir/.env"
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

  # Start Elasticsearch and wait for it to respond to REST requests.
  start_container "${ES_LOCAL_CONTAINER_NAME}" || exit 1
  es_check="curl --noproxy '*' --output /dev/null --silent --head --fail -u elastic:${ES_LOCAL_PASSWORD} ${ES_LOCAL_URL}"
  wait_for_healthcheck "${ES_LOCAL_CONTAINER_NAME}" "${ES_LOCAL_CONTAINER_NAME}" "$es_check" || exit 1
  get_elasticsearch_ip || exit 1

  # Create Elasticsearch API key for local use on first start.
  if [ -z "${ES_LOCAL_API_KEY:-}" ]; then
    create_elasticsearch_api_key
  fi

  check_license

  if [ -n "${KIBANA_LOCAL_CONTAINER_NAME:-}" ]; then
    # Configure Kibana system_user password before starting Kibana.
    configure_kibana_system_user_password

    # Start Kibana and wait for it to respond to REST requests.
    create_kibana_container || exit 1
    start_container "${KIBANA_LOCAL_CONTAINER_NAME}" || exit 1
    kibana_check="curl --noproxy '*' -s -I http://127.0.0.1:${KIBANA_LOCAL_PORT} | grep -q 'HTTP/1.1 302 Found'"
    wait_for_healthcheck "${KIBANA_LOCAL_CONTAINER_NAME}" "${KIBANA_LOCAL_CONTAINER_NAME}" "$kibana_check" || exit 1
  fi

  if [ -n "${EDOT_LOCAL_CONTAINER_NAME:-}" ]; then
    # Start edot-collector and wait for it to respond to requests.
    create_edot_container || exit 1
    start_container "${EDOT_LOCAL_CONTAINER_NAME}" || exit 1
    # The OTLP HTTP endpoint answers with an HTTP status (e.g. 404) when it is ready.
    edot_check="curl --noproxy '*' -s -o /dev/null http://127.0.0.1:4318"
    wait_for_healthcheck "${EDOT_LOCAL_CONTAINER_NAME}" "${EDOT_LOCAL_CONTAINER_NAME}" "$edot_check" || exit 1
  fi
}

main
EOM
  } > ./start.sh
  chmod +x ./start.sh
}

write_stop_script() {
  {
    script_header
    cat <<'EOM'
set -eu

script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$script_dir/common.sh"

stop_container() {
  # stop_container <container-name>
  name=${1:?container name required}

  # shellcheck disable=SC2059
  printf "Stopping container '$name' ... "

  # If container doesn't exist, nothing to do.
  if ! container_exists "$name"; then
    echo "done (does not exist)."
    return 0
  fi

  if ! container_running "$name"; then
    echo "done (already stopped)."
    return 0
  fi

  # Try graceful stop.
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

main() {
  if [ -n "${EDOT_LOCAL_CONTAINER_NAME:-}" ]; then
    stop_container "${EDOT_LOCAL_CONTAINER_NAME}"
  fi

  if [ -n "${KIBANA_LOCAL_CONTAINER_NAME:-}" ]; then
    stop_container "${KIBANA_LOCAL_CONTAINER_NAME}"
  fi

  stop_container "${ES_LOCAL_CONTAINER_NAME}"
}

main
EOM
  } > ./stop.sh
  chmod +x ./stop.sh
}

write_down_script() {
  {
    script_header
    cat <<'EOM'
set -eu

script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$script_dir/common.sh"

remove_network() {
  [ -n "${CONTAINER_NETWORK_NAME:-}" ] || { echo "CONTAINER_NETWORK_NAME not set"; return 1; }

  # shellcheck disable=SC2059
  printf "Removing network '${CONTAINER_NETWORK_NAME}' ... "

  if ! "$CONTAINER_CLI" network inspect "${CONTAINER_NETWORK_NAME}" >/dev/null 2>&1; then
    echo "done (does not exist)."
    return 0
  fi

  if "$CONTAINER_CLI" network delete "${CONTAINER_NETWORK_NAME}" >/dev/null 2>&1; then
    echo "done (removed)."
    return 0
  fi

  echo "failed."
  echo "The network may still be in use, retry later: '${CONTAINER_CLI} network delete ${CONTAINER_NETWORK_NAME}'"
  return 1
}

remove_volume() {
  # remove_volume <volume-name>
  [ -n "${1:-}" ] || { echo "Usage: remove_volume <volume-name>"; return 1; }

  vol="$1"

  # shellcheck disable=SC2059
  printf "Removing volume '$vol' ... "

  if ! "$CONTAINER_CLI" volume inspect "$vol" >/dev/null 2>&1; then
    echo "done (does not exist)."
    return 0
  fi

  if "$CONTAINER_CLI" volume delete "$vol" >/dev/null 2>&1; then
    echo "done (removed)."
    return 0
  fi

  echo "failed."
  echo "Volume '${vol}' may be in use. Stop the containers and retry: '${CONTAINER_CLI} volume delete ${vol}'"
  return 1
}

remove_container() {
  # remove_container <container-name>
  name=${1:?container name required}

  # shellcheck disable=SC2059
  printf "Removing container '$name' ... "

  # If container doesn't exist, nothing to do.
  if ! container_exists "$name"; then
    echo "done (does not exist)."
    return 0
  fi

  # Delete the container, stopping it if it is still running.
  if "$CONTAINER_CLI" delete --force "$name" >/dev/null 2>&1; then
    echo "done (removed)."
    return 0
  fi

  echo "failed."
  return 1
}

main() {
  if [ -n "${EDOT_LOCAL_CONTAINER_NAME:-}" ]; then
    remove_container "${EDOT_LOCAL_CONTAINER_NAME}"
  fi

  if [ -n "${KIBANA_LOCAL_CONTAINER_NAME:-}" ]; then
    remove_container "${KIBANA_LOCAL_CONTAINER_NAME}"
    remove_volume "${KIBANA_LOCAL_VOLUME_NAME}"
  fi

  remove_container "${ES_LOCAL_CONTAINER_NAME}"
  remove_volume "${ES_LOCAL_VOLUME_NAME}"
  remove_network
}

main
EOM
  } > ./down.sh
  chmod +x ./down.sh
}

write_uninstall_script() {
  {
    script_header
    cat <<'EOM'
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
    exit 1
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

  "$script_dir/down.sh" || true

  rm -f "$script_dir/.env"
  rm -f "$script_dir/common.sh"
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
    echo "- docker.elastic.co/elastic-agent/elastic-otel-collector:${ES_LOCAL_VERSION}"
  fi

  if ! ask_confirmation; then
    echo "Elastic start-local successfully removed."
    return 0
  fi

  $CONTAINER_CLI image delete "docker.elastic.co/elasticsearch/elasticsearch:${ES_LOCAL_VERSION}" >/dev/null 2>&1 || \
    echo "Failed to remove 'docker.elastic.co/elasticsearch/elasticsearch' image."

  if [ -n "${KIBANA_LOCAL_CONTAINER_NAME:-}" ]; then
    $CONTAINER_CLI image delete "docker.elastic.co/kibana/kibana:${ES_LOCAL_VERSION}" >/dev/null 2>&1 || \
      echo "Failed to remove 'docker.elastic.co/kibana/kibana' image."
  fi

  if [ -n "${EDOT_LOCAL_CONTAINER_NAME:-}" ]; then
    $CONTAINER_CLI image delete "docker.elastic.co/elastic-agent/elastic-otel-collector:${ES_LOCAL_VERSION}" >/dev/null 2>&1 || \
      echo "Failed to remove 'docker.elastic.co/elastic-agent/elastic-otel-collector' image."
  fi

  echo "Elastic start-local successfully removed."
}

main
EOM
  } > ./uninstall.sh
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
  # shellcheck disable=SC1091
  . ./.env

  if [ -n "${ES_LOCAL_API_KEY:-}" ]; then
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

# Trap SIGINT and call ctrl_c().
trap ctrl_c INT

# Execute the entry point function.
main "$@"

####################################################################################################
