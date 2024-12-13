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
  version="0.5.0"

  # Folder name for the installation
  installation_folder="elastic-start-local"
  # API key name for Elasticsearch
  api_key_name="elastic-start-local"
  # Name of the error log
  error_log="error-start-local.log"
  # Minimum version for docker-compose
  min_docker_compose="1.29.0"
  # Elasticsearch container name
  elasticsearch_container_name="es-local-dev"
  # Kibana container name
  kibana_container_name="kibana-local-dev"
  # Minimum disk space required for docker images + services (in GB)
  min_disk_space_required=5
}

# Get linux distribution
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
  elif [[ "$OSTYPE" == "darwin"* ]]; then
      # macOS detection
      echo "Distribution: macOS"
      echo "Version: $(sw_vers -productVersion)"
  elif [[ "$OSTYPE" == "cygwin" || "$OSTYPE" == "msys" || "$OSTYPE" == "win32" ]]; then
      # Windows detection in environments like Git Bash, Cygwin, or MinGW
      echo "Distribution: Windows"
      echo "Version: $(cmd.exe /c ver | tr -d '\r')"
  elif [[ "$OSTYPE" == "linux-gnu" && "$(uname -r)" == *"Microsoft"* ]]; then
      # Windows Subsystem for Linux (WSL) detection
      echo "Distribution: Windows (WSL)"
      echo "Version: $(uname -r)"
  else
      echo "Unknown operating system"
  fi
}

# Check if a command exists
available() { command -v $1 >/dev/null; }

# Revert the status, removing containers, volumes, network and folder
cleanup() {
  if [ -d "./../$folder_to_clean" ]; then
    if [ -f "docker-compose.yml" ]; then
      $docker_clean >/dev/null 2>&1
      $docker_remove_volumes >/dev/null 2>&1
    fi
    cd ..
    rm -rf ${folder_to_clean}
  fi
}

# Generate the error log
# parameter 1: error message
# parameter 2: the container names to retrieve, separated by comma
generate_error_log() {
  local msg=$1
  local docker_services=$2
  local error_file="$error_log"
  if [ -d "./../$folder_to_clean" ]; then
    error_file="./../$error_log"
  fi
  if [ -n "${msg}" ]; then
    echo "${msg}" > "$error_file"
  fi
  echo "Docker engine: $(docker --version)" >> "$error_file" 
  echo "Docker compose: ${docker_version}" >> "$error_file"
  echo $(get_os_info) >> "$error_file"
  for service in $docker_services; do
    echo "-- Logs of service ${service}:" >> "$error_file"
    docker logs "${service}" >> "$error_file" 2> /dev/null
  done
  echo "An error log has been generated in ${error_log} file."
  echo "If you need assistance, open an issue at https://github.com/elastic/start-local/issues"
}

# Compare versions
# parameter 1: version to compare
# parameter 2: version to compare
compare_versions() {
  local v1=$1
  local v2=$2

  original_ifs="$IFS"  
  IFS='.'; set -- $v1; v1_major=$1; v1_minor=$2; v1_patch=$3
  IFS='.'; set -- $v2; v2_major=$1; v2_minor=$2; v2_patch=$3
  IFS="$original_ifs"

  [ "$v1_major" -lt "$v2_major" ] && echo "lt" && return 0
  [ "$v1_major" -gt "$v2_major" ] && echo "gt" && return 0

  [ "$v1_minor" -lt "$v2_minor" ] && echo "lt" && return 0
  [ "$v1_minor" -gt "$v2_minor" ] && echo "gt" && return 0

  [ "$v1_patch" -lt "$v2_patch" ] && echo "lt" && return 0
  [ "$v1_patch" -gt "$v2_patch" ] && echo "gt" && return 0

  echo "eq"
}

# Wait for availability of Kibana
# parameter: timeout in seconds
wait_for_kibana() {
  local timeout="${1:-60}"
  echo "- Waiting for Kibana to be ready"
  echo
  local start_time="$(date +%s)"
  until curl -s -I http://localhost:5601 | grep -q 'HTTP/1.1 302 Found'; do
    elapsed_time="$(($(date +%s) - start_time))"
    if [ "$elapsed_time" -ge "$timeout" ]; then
      error_msg="Error: Kibana timeout of ${timeout} sec"
      echo $error_msg
      generate_error_log "${error_msg}" "${elasticsearch_container_name} ${kibana_container_name} kibana_settings"
      cleanup
      exit 1
    fi
    sleep 2
  done
}

# Generates a random password with letters and numbers
# parameter: size of the password (default is 8 characters)
random_password() {
  local LENGTH="${1:-8}"
  echo $(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c ${LENGTH})
}

# Create an API key for Elasticsearch
# parameter 1: the Elasticsearch password
# parameter 2: name of the API key to generate
create_api_key() {
  local es_password=$1
  local name=$2
  local response="$(curl -s -u "elastic:${es_password}" -X POST http://localhost:9200/_security/api_key -d "{\"name\": \"${name}\"}" -H "Content-Type: application/json")"
  if [ -z "$response" ]; then
    echo ""
  else
    local api_key="$(echo "$response" | grep -Eo '"encoded":"[A-Za-z0-9+/=]+' | grep -Eo '[A-Za-z0-9+/=]+' | tail -n 1)"
    echo $api_key
  fi
}

# Check if a container is runnning
# parameter: the name of the container
check_container_running() {
  local container_name=$1
  local containers=$(docker ps --format '{{.Names}}')
  if $(echo "$containers" | grep -q "^${container_name}$"); then
    echo "The docker container '$container_name' is already running!"
    echo "You can have only one running at time."
    echo "To stop the container run the following command:"
    echo
    echo "docker stop $container_name"
    exit 1
  fi
}

# Check the available disk space in GB
# parameter: required size in GB
check_disk_space_gb() {
  local required=$1
  local available_gb=$(($(df -k / | awk 'NR==2 {print $4}') / 1024 / 1024))
  if [ $available_gb -lt $required ]; then
    echo "Error: only ${available_gb} GB of disk space available; ${required} GB required for the installation"
    exit 1
  fi
}

check_requirements() {
  # Check the requirements
  check_disk_space_gb ${min_disk_space_required}
  if ! available "curl"; then
    echo "Error: curl command is required"
    echo "You can install it from https://curl.se/download.html."
    exit 1
  fi
  if ! available "grep"; then
    echo "Error: grep command is required"
    echo "You can install it from https://www.gnu.org/software/grep/."
    exit 1
  fi
  need_wait_for_kibana=true
  # Check for "docker compose" or "docker-compose"
  set +e
  docker compose >/dev/null 2>&1
  if [ $? -ne 0 ]; then
    if ! available "docker-compose"; then
      if ! available "docker"; then
        echo "Error: docker command is required"
        echo "You can install it from https://docs.docker.com/engine/install/."
        exit 1
      fi
      echo "Error: docker compose is required"
      echo "You can install it from https://docs.docker.com/compose/install/"
      exit 1
    fi
    docker="docker-compose up -d"
    docker_stop="docker-compose stop"
    docker_clean="docker-compose rm -fsv"
    docker_remove_volumes="docker-compose down -v"
    docker_version=$(docker-compose --version | head -n 1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+')
    if [ $(compare_versions "$docker_version" "$min_docker_compose") = "lt" ]; then
      echo "Unfortunately we don't support docker compose ${docker_version}. The minimum required version is $min_docker_compose."
      echo "You can migrate you docker compose from https://docs.docker.com/compose/migrate/"
      cleanup
      exit 1
    fi 
  else
    docker_stop="docker compose stop"
    docker_clean="docker compose rm -fsv"
    docker_remove_volumes="docker compose down -v"
    docker_version=$(docker compose version | head -n 1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+')
    # --wait option has been introduced in 2.1.1+
    if [ "$(compare_versions "$docker_version" "2.1.0")" = "gt" ]; then
      docker="docker compose up --wait"
      need_wait_for_kibana=false
    else
      docker="docker compose up -d"
    fi
  fi
  set -e
}

check_installation_folder() {
  # Check if $installation_folder exists
  folder=$installation_folder
  if [ -d "$folder" ]; then
    if [ -n "$(ls -A "$folder")" ]; then
      echo "It seems you have already a start-local installation in '${folder}'."
      if [ -f "$folder/uninstall.sh" ]; then
        echo "I cannot proceed unless you uninstall it, using the following command:"
        echo "cd $folder && ./uninstall.sh"
      else
        echo "I did not find the uninstall.sh file, you need to proceed manually."
        if [ -f "$folder/docker-compose.yml" ] && [ -f "$folder/.env" ]; then
          echo "Execute the following commands:"
          echo "cd $folder"
          echo $docker_clean
          echo $docker_remove_volumes
          echo "cd .."
          echo "rm -rf $folder"
        fi
        echo "Finally, remove the folder '${folder}' and try again."
        exit 1
      fi
    fi
  fi
}

check_docker_services() {
  # Check for docker containers running
  check_container_running "$elasticsearch_container_name"
  check_container_running "$kibana_container_name"
  check_container_running "kibana_settings"
}

create_installation_folder() {
  # If $folder already exists, it is empty, see above
  if [ ! -d "$folder" ]; then 
    mkdir $folder
  fi
  cd $folder
  folder_to_clean=$folder
}

generate_passwords_api_keys() {
  # Generate random passwords
  es_password="$(random_password)"
  kibana_password="$(random_password)"
  es_version="8.17.0"
  kibana_encryption_key="$(random_password 32)"
}

create_env_file() {
  # Create the .env file
  cat > .env <<- EOM
ES_LOCAL_VERSION=$es_version
ES_LOCAL_CONTAINER_NAME=$elasticsearch_container_name
ES_LOCAL_PASSWORD=$es_password
ES_LOCAL_URL=http://localhost:9200
ES_LOCAL_PORT=9200
ES_LOCAL_HEAP_INIT=128m
ES_LOCAL_HEAP_MAX=2g
ES_LOCAL_DISK_SPACE_REQUIRED=1gb
KIBANA_LOCAL_CONTAINER_NAME=$kibana_container_name
KIBANA_LOCAL_PORT=5601
KIBANA_LOCAL_PASSWORD=$kibana_password
KIBANA_ENCRYPTION_KEY=$kibana_encryption_key
EOM
}

# Create the start script (start.sh)
# including the license update if trial expired
create_start_file() {
  local today=$(date +%s)
  local expire=$((today + 3600*24*30))

  cat > start.sh <<-'EOM'
#!/bin/sh
# Start script for start-local
# More information: https://github.com/elastic/start-local
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd ${SCRIPT_DIR}
today=$(date +%s)
. ./.env
# Check disk space
available_gb=$(($(df -k / | awk 'NR==2 {print $4}') / 1024 / 1024))
required=$(echo "${ES_LOCAL_DISK_SPACE_REQUIRED}" | grep -Eo '[0-9]+')
if [ $available_gb -lt $required ]; then
  echo "----------------------------------------------------------------------------"
  echo "WARNING: Disk space is below the ${required} GB limit. Elasticsearch will be"
  echo "executed in read-only mode. Please free up disk space to resolve this issue."
  echo "----------------------------------------------------------------------------"
  echo "Press ENTER to confirm."
  read answer
fi
EOM
  if [ "$need_wait_for_kibana" = true ]; then
    cat >> start.sh <<-'EOM'
wait_for_kibana() {
  local timeout="${1:-60}"
  echo "- Waiting for Kibana to be ready"
  echo
  local start_time="$(date +%s)"
  until curl -s -I http://localhost:5601 | grep -q 'HTTP/1.1 302 Found'; do
    elapsed_time="$(($(date +%s) - start_time))"
    if [ "$elapsed_time" -ge "$timeout" ]; then
      echo "Error: Kibana timeout of ${timeout} sec"
      exit 1
    fi
    sleep 2
  done
}

EOM
  fi

  cat >> start.sh <<- EOM
if [ ! -n "\${ES_LOCAL_LICENSE:-}" ] && [ "\$today" -gt $expire ]; then
  echo "---------------------------------------------------------------------"
  echo "The one-month trial period has expired. You can continue using the"
  echo "Free and open Basic license or request to extend the trial for"
  echo "another 30 days using this form:"
  echo "https://www.elastic.co/trialextension"
  echo "---------------------------------------------------------------------"
  echo "For more info about the license: https://www.elastic.co/subscriptions"
  echo
  echo "Updating the license..."
  $docker elasticsearch >/dev/null 2>&1
  result=\$(curl -s -X POST "\${ES_LOCAL_URL}/_license/start_basic?acknowledge=true" -H "Authorization: ApiKey \${ES_LOCAL_API_KEY}" -o /dev/null -w '%{http_code}\n')
  if [ "\$result" = "200" ]; then
    echo "✅ Basic license successfully installed"
    echo "ES_LOCAL_LICENSE=basic" >> .env
  else 
    echo "Error: I cannot update the license"
    result=\$(curl -s -X GET "\${ES_LOCAL_URL}" -H "Authorization: ApiKey \${ES_LOCAL_API_KEY}" -o /dev/null -w '%{http_code}\n')
    if [ "\$result" != "200" ]; then
      echo "Elasticsearch is not running."
    fi
    exit 1
  fi
  echo
fi
$docker
EOM

  if [ "$need_wait_for_kibana" = true ]; then
    cat >> start.sh <<-'EOM'
wait_for_kibana 120
EOM
  fi
  chmod +x start.sh
}

# Create the stop script (stop.sh)
create_stop_file() {
  cat > stop.sh <<-'EOM'
#!/bin/sh
# Stop script for start-local
# More information: https://github.com/elastic/start-local
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd ${SCRIPT_DIR}
EOM

  cat >> stop.sh <<- EOM
$docker_stop
EOM
  chmod +x stop.sh
}

# Create the uninstall script (uninstall.sh)
create_uninstall_file() {

  cat > uninstall.sh <<-'EOM'
#!/bin/sh
# Uninstall script for start-local
# More information: https://github.com/elastic/start-local
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

ask_confirmation() {
    echo "Do you want to continue? (yes/no)"
    read answer
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

cd ${SCRIPT_DIR}
if [ ! -e "docker-compose.yml" ]; then
  echo "Error: I cannot find the docker-compose.yml file"
  echo "I cannot uninstall start-local."
fi
if [ ! -e ".env" ]; then
  echo "Error: I cannot find the .env file"
  echo "I cannot uninstall start-local."
fi
echo "This script will uninstall start-local."
echo "All data will be deleted and cannot be recovered."
if ask_confirmation; then
EOM

  cat >> uninstall.sh <<- EOM
  $docker_clean
  $docker_remove_volumes
  rm docker-compose.yml .env uninstall.sh start.sh stop.sh
  echo "Start-local successfully removed"
fi
EOM
  chmod +x uninstall.sh
}

create_docker_compose_file() {
  # Create the docker-compose-yml file
  cat > docker-compose.yml <<-'EOM'
services:
  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:${ES_LOCAL_VERSION}
    container_name: ${ES_LOCAL_CONTAINER_NAME}
    volumes:
      - dev-elasticsearch:/usr/share/elasticsearch/data
    ports:
      - 127.0.0.1:${ES_LOCAL_PORT}:9200
    environment:
      - discovery.type=single-node
      - ELASTIC_PASSWORD=${ES_LOCAL_PASSWORD}
      - xpack.security.enabled=true
      - xpack.security.http.ssl.enabled=false
      - xpack.license.self_generated.type=trial
      - xpack.ml.use_auto_machine_memory_percent=true
      - ES_JAVA_OPTS=-Xms${ES_LOCAL_HEAP_INIT} -Xmx${ES_LOCAL_HEAP_MAX}
      - cluster.routing.allocation.disk.watermark.low=${ES_LOCAL_DISK_SPACE_REQUIRED}
      - cluster.routing.allocation.disk.watermark.high=${ES_LOCAL_DISK_SPACE_REQUIRED}
      - cluster.routing.allocation.disk.watermark.flood_stage=${ES_LOCAL_DISK_SPACE_REQUIRED}
    ulimits:
      memlock:
        soft: -1
        hard: -1
    healthcheck:
      test:
        [
          "CMD-SHELL",
          "curl --output /dev/null --silent --head --fail -u elastic:${ES_LOCAL_PASSWORD} http://elasticsearch:${ES_LOCAL_PORT}",
        ]
      interval: 5s
      timeout: 5s
      retries: 10

  kibana_settings:
    depends_on:
      elasticsearch:
        condition: service_healthy
    image: docker.elastic.co/elasticsearch/elasticsearch:${ES_LOCAL_VERSION}
    container_name: kibana_settings
    restart: 'no'
    command: >
      bash -c '
        echo "Setup the kibana_system password";
        start_time=$(date +%s);
        timeout=60;
        until curl -s -u "elastic:${ES_LOCAL_PASSWORD}" -X POST http://elasticsearch:${ES_LOCAL_PORT}/_security/user/kibana_system/_password -d "{\"password\":\"'${KIBANA_LOCAL_PASSWORD}'\"}" -H "Content-Type: application/json" | grep -q "^{}"; do if [ $(($(date +%s) - $$start_time)) -ge $$timeout ]; then echo "Error: Elasticsearch timeout"; exit 1; fi; sleep 2; done;
      '

  kibana:
    depends_on:
      kibana_settings:
        condition: service_completed_successfully
    image: docker.elastic.co/kibana/kibana:${ES_LOCAL_VERSION}
    container_name: ${KIBANA_LOCAL_CONTAINER_NAME}
    volumes:
      - dev-kibana:/usr/share/kibana/data
    ports:
      - 127.0.0.1:${KIBANA_LOCAL_PORT}:5601
    environment:
      - SERVER_NAME=kibana
      - ELASTICSEARCH_HOSTS=http://elasticsearch:9200
      - ELASTICSEARCH_USERNAME=kibana_system
      - ELASTICSEARCH_PASSWORD=${KIBANA_LOCAL_PASSWORD}
      - XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY=${KIBANA_ENCRYPTION_KEY}
      - ELASTICSEARCH_PUBLICBASEURL=http://localhost:${ES_LOCAL_PORT}
    healthcheck:
      test:
        [
          "CMD-SHELL",
          "curl -s -I http://kibana:5601 | grep -q 'HTTP/1.1 302 Found'",
        ]
      interval: 10s
      timeout: 10s
      retries: 20

volumes:
  dev-elasticsearch:
  dev-kibana:
EOM
}

print_steps() {
  echo "⌛️ Setting up Elasticsearch and Kibana v${es_version}..."
  echo
  echo "- Generated random passwords"
  echo "- Created the ${folder} folder containing the files:"
  echo "  - .env, with settings"
  echo "  - docker-compose.yml, for Docker services"
  echo "  - start/stop/uninstall commands"
}

running_docker_compose() {
  # Execute docker compose
  echo "- Running ${docker}"
  echo
  set +e
  $docker
  if [ $? -ne 0 ]; then
    error_msg="Error: ${docker} command failed!"
    echo $error_msg
    generate_error_log "${error_msg}" "${elasticsearch_container_name} ${kibana_container_name} kibana_settings"
    cleanup
    exit 1
  fi
  set -e
}

api_key() {
  # Create an API key for Elasticsearch
  api_key=$(create_api_key $es_password $api_key_name)
  if [ -n "$api_key" ]; then
    echo "ES_LOCAL_API_KEY=${api_key}" >> .env
  fi
}

kibana_wait() {
  if [ "$need_wait_for_kibana" = true ]; then
    wait_for_kibana 120
  fi
}

success() {
  echo
  echo "🎉 Congrats, Elasticsearch and Kibana are installed and running in Docker!"
  echo

  echo "🌐 Open your browser at http://localhost:5601"
  echo
  echo "   Username: elastic"
  echo "   Password: ${es_password}"
  echo

  echo "🔌 Elasticsearch API endpoint: http://localhost:9200"
  if [ -n "$api_key" ]; then
    echo "🔑 API key: $api_key"
    echo
  else
    echo "🔑 Use basic auth or create an API key"
    echo "https://www.elastic.co/guide/en/kibana/current/api-keys.html"
    echo
  fi
  echo
  echo "Learn more at https://github.com/elastic/start-local"

  echo
}

main() {
  startup
  check_requirements
  check_installation_folder
  check_docker_services
  create_installation_folder
  generate_passwords_api_keys
  create_start_file
  create_stop_file
  create_uninstall_file
  create_env_file
  create_docker_compose_file
  print_steps
  running_docker_compose
  api_key
  kibana_wait
  success
}

ctrl_c() { 
  cleanup
  exit 1
}

# Trap ctrl-c
trap ctrl_c INT

# Execute the script
main