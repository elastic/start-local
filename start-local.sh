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
  available "docker" && has_docker=true || has_docker=false
  available "podman" && has_podman=true || has_podman=false

  if [ "$has_docker" = "false" ] && [ "$has_podman" = "false" ]; then
    echo "Error: Either Docker or Podman must be installed"
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
  # TODO: Inline contents.
  cp ../container-create.sh ./initialize.sh
  chmod +x ./initialize.sh
  cp ../container-start.sh ./start.sh
  chmod +x ./start.sh
  cp ../container-stop.sh ./stop.sh
  chmod +x ./stop.sh
  cp ../container-destroy.sh ./finalize.sh
  chmod +x ./finalize.sh
  cp ../uninstall.sh ./uninstall.sh
  chmod +x ./uninstall.sh
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

  # TODO: Inline contents.
  cp "$script_dir/edot-config.yaml" "$installation_folder/config/edot-collector/config.yaml"
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

  if ( set +e; ./initialize.sh && ./start.sh ); then
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
