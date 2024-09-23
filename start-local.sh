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

echo
echo '  ______ _           _   _      '
echo ' |  ____| |         | | (_)     '
echo ' | |__  | | __ _ ___| |_ _  ___ '
echo ' |  __| | |/ _` / __| __| |/ __|'
echo ' | |____| | (_| \__ \ |_| | (__ '
echo ' |______|_|\__,_|___/\__|_|\___|'
echo '--------------------------------------------------------'
echo '🚀 Run Elasticsearch and Kibana for local testing'
echo '--------------------------------------------------------'
echo 
echo 'ℹ️ Do not use this script in a production environment'
echo

# Version
version="0.2.0"

# Folder name for the installation
installation_folder="elastic-start-local"
# API key name for Elasticseach
api_key_name="elastic-start-local"
# Name of the error log
error_log="error-start-local.log"
# Minimum version for docker-compose
min_docker_compose="1.29.0"
# Elasticsearch container name
elasticsearch_container_name="es-local-dev"
# Kibana container name
kibana_container_name="kibana-local-dev"

# Trap ctrl-c
trap ctrl_c INT

ctrl_c() { 
  cleanup
  exit 1
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

# Revert the status, removeìing containers, volumes, network and folder
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
generate_error_log() {
  local msg=$1
  if [ -n "${msg}" ]; then
    echo "${msg}" > "$error_log"
  fi
  echo "Docker engine: $(docker --version)" >> "$error_log" 
  echo "Docker compose: ${docker_version}" >> "$error_log"
  echo $(get_os_info) >> "$error_log"
  echo "An error log has been generated in ${error_log}"
  echo "If you report this error in https://github.com/elastic/start-local/issues, we'll try to fix it. Thanks!"
}

# Compare versions
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
      error_msg="Error: timeout of ${timeout} sec waiting for Kibana"
      echo $error_msg
      cleanup
      generate_error_log $error_msg
      exit 1
    fi
    sleep 2
  done
}

# Generates a random password with letters and numbers
# You can pass the size of the password as first parameter (default is 8 characters)
random_password() {
  local LENGTH="${1:-8}"
  echo $(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c ${LENGTH})
}

# Returns the latest Elasticsearch tag version
get_latest_version() {
  local tags="$(curl -s "https://api.github.com/repos/elastic/elasticsearch/tags")"
  local latest="$(echo "$tags" | grep -m 1 '"name"' | grep -Eo '[0-9.]+')"
  echo $latest
}

# Create an API key for Elasticsearch
# You need to pass the Elasticsearch password and the name of the key
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

# Check if a docker container is runnning
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

# Check the requirements
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

# Check if elastic-start-local exists
folder=$installation_folder
if [ -d "$folder" ]; then
  echo "It seems you have already a start-local in the directory $folder."
  echo "I cannot proceed unless you remove it or move to another folder."
  echo "Before removing the folder remember to delete the docker services."
  echo "You can use the following commands (data will be destroyed):"
  echo "cd $folder"
  echo $docker_clean
  exit 1
fi

# Check for docker containers running
check_container_running "$elasticsearch_container_name"
check_container_running "$kibana_container_name"

mkdir $folder
cd $folder
folder_to_clean=$folder

# Generate random passwords
es_password="$(random_password)"
kibana_password="$(random_password)"
es_version="$(get_latest_version)"
kibana_encryption_key="$(random_password 32)"

# Create the .env file
cat > .env <<- EOM
ES_LOCAL_VERSION=$es_version
ES_LOCAL_CONTAINER_NAME=$elasticsearch_container_name
ES_LOCAL_PASSWORD=$es_password
ES_LOCAL_PORT=9200
ES_LOCAL_HEAP_INIT=128m
ES_LOCAL_HEAP_MAX=2g
KIBANA_LOCAL_CONTAINER_NAME=$kibana_container_name
KIBANA_LOCAL_PORT=5601
KIBANA_LOCAL_PASSWORD=$kibana_password
KIBANA_ENCRYPTION_KEY=$kibana_encryption_key
EOM

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
        until curl -s -u "elastic:${ES_LOCAL_PASSWORD}" -X POST http://elasticsearch:${ES_LOCAL_PORT}/_security/user/kibana_system/_password -d "{\"password\":\"'${KIBANA_LOCAL_PASSWORD}'\"}" -H "Content-Type: application/json" | grep -q "^{}"; do sleep 5; done;
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

echo "⌛️Setting up Elasticsearch and Kibana v${es_version}..."
echo "- Created the ${folder} folder"
echo "- Generated random passwords"
echo "- Created a .env file with settings"
echo "- Created a docker-compose.yml file"

# Execute docker compose
echo "- Running ${docker}"
set +e
$docker
if [ $? -ne 0 ]; then
  error_msg="Error: the ${docker} command failed!"
  echo $error_msg
  cleanup
  generate_error_log $error_msg
  exit 1
fi
set -e

# Create an API key for Elasticsearch
api_key=$(create_api_key $es_password $api_key_name)
if [ -n "$api_key" ]; then
  echo "ES_LOCAL_API_KEY=${api_key}" >> .env
fi

if [ "$need_wait_for_kibana" = true ]; then
  wait_for_kibana 120
fi

# Success
echo
echo "🎉 Congrats, Elasticsearch and Kibana are successfully installed and running!"
echo
echo "🌐 Access Kibana at http://localhost:5601"
echo "Use 'elastic' as username and '${es_password}' as password."
echo
echo "🛠️ Configuration details"
echo "We created the folder '${folder}' containing the following files:"
echo "  - docker-compose.yml: Use this file to manage the services."
echo "  - .env: This file contains environment variables and credentials."
echo "Learn more at https://github.com/elastic/start-local"
echo
if [ -n "$api_key" ]; then
  echo "🔑 An API key for Elasticsearch has been created (stored in .env):"
  echo $api_key
  echo
  echo "ℹ️ Use this API key to connect to Elasticsearch (http://localhost:9200)"
  echo "Using cURL you can test the connection with the command:"
  echo "curl http://localhost:9200 -H 'Authorization: ApiKey ${api_key}'"
else
  echo "ℹ️ To connect to Elasticsearch use http://localhost:9200"
  echo "You can use basic authentication with elastic user and ${es_password} password"
  echo "Or create an API key as reported at https://www.elastic.co/guide/en/kibana/current/api-keys.html"
fi
echo "Learn more about our SDK at https://www.elastic.co/guide/en/elasticsearch/client"

