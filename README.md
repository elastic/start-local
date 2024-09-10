# Try Elasticsearch and Kibana locally

Try Elasticsearch and Kibana using a simple shell script for local
development. It uses [docker](https://www.docker.com/) to install
the services and offers a trial [Platinum](https://www.elastic.co/subscriptions)
license for 1 month. After the month the license will become
[Free and Open Basic](https://www.elastic.co/subscriptions).

For instance, the Platinum version offers [ELSER](https://www.elastic.co/guide/en/machine-learning/current/ml-nlp-elser.html) retrieval model and the [Inference API](https://www.elastic.co/guide/en/elasticsearch/reference/current/inference-apis.html).
The Free and Open Basic includes the [vector search](https://www.elastic.co/what-is/vector-search) 
and [ES|QL](https://www.elastic.co/guide/en/elasticsearch/reference/current/esql.html).
For a full list of subscription and features [read this page](https://www.elastic.co/subscriptions).

This script can be executed only on Linux and Mac environments.
We do not support Microsoft Windows at the moment.

**Please note**: this script is only for local testing, do not
run it in a production environment!

For production installation please reference to the [official documentation](https://www.elastic.co/downloads/elasticsearch).
For Kibana, [this is the page](https://www.elastic.co/downloads/kibana) to read.

## How to execute the script

The **start-local** script has been designed to be executed using [curl](https://curl.se/),
as follows (NOTE: the script has not yet been published on elastic.co):

```bash
curl -fsSL https://elastic.co/start-local | sh
```

The script will create a n `elastic-start-local` folder with two files:
`docker-compose.yml` and `.env`. The first `docker-compose.yml` is a standard
docker file containing the configurations for Elasticsearch and Kibana services.
The second file `.env` contains all the settings, like the Elasticsearch password.

## After the execution

After executing the start-local script you will have Elasticsearch
running on http://localhost:9200 and Kibana on http://localhost:5601.

The script generates a random password for the `elastic` user. The password
is displayed at the end of the installation.

We disabled HTTPS and we used Basic acces authentication to connect to Elasticsearch.
This configuration should be used only for local testing.
For security reason, Elasticsearch and Kibana are accessible only using localhost.

We also generated an API key for Elasticsearch, this can be useful to connect
to Elasticsearch using the [Elastic SDK](https://www.elastic.co/guide/en/elasticsearch/client)
or directly with [REST API](https://www.elastic.co/guide/en/elasticsearch/reference/current/rest-apis.html). 
The API key is stored in the `.env` file with the key `ES_LOCAL_API_KEY`.

## Docker compose

If you go into the `elastic-start-local` folder you can manage the services
using the [docker compose](https://docs.docker.com/reference/cli/docker/compose/) commands.

For instance, to restart the services, you can run the command:

```bash
docker compose up --wait
```
To stop the services you can run the command:

```bash
docker compose stop
```

To delete the service and the volumes, you can run the command:

```bash
docker compose rm -fsv
```

We support also the `docker-compose` command with a dash. In this case,
you need to use the following commands:


```bash
docker-compose up -d    # start the services
docker-compose stop     # stop the service
docker-compose rm -fsv  # delete the services and the volumes
```

## Logging

You can access the log of Elasticsearch and Kibana using the [docker logs](https://docs.docker.com/reference/cli/docker/container/logs/) command.

For instance, if you want to read the log of Elasticsearch you need to
run the following command:

```bash
docker logs es-local-dev
```

where `es-local-dev` is the docker container name of Elasticsearch
specified in the `.env` file with the `ES_LOCAL_CONTAINER_NAME` env variable.

For the Kibana log you can execute the following command:

```bash
docker logs kibana-local-dev
```

where `kibana-local-dev` is the docker container name of Kibana
specified in the `.env` file with the `KIBANA_LOCAL_CONTAINER_NAME` env
variable.

## How to change the settings

If you want to change the settings, for instance the Elasticsearch password,
you can edit the `.env` file and change the values.

The `.env` file contains some settings like as follows:

```bash
ES_LOCAL_VERSION="8.14.2"
ES_LOCAL_CONTAINER_NAME="es-local-dev"
ES_LOCAL_DOCKER_NETWORK="elastic-net"
ES_LOCAL_PASSWORD="hOalVFrN"
ES_LOCAL_PORT="9200"
KIBANA_LOCAL_CONTAINER_NAME="kibana-local-dev"
KIBANA_LOCAL_PORT="5601"
KIBANA_LOCAL_PASSWORD="YJFbhLJL"
```

Where `ES_LOCAL_VERSION` is the Elasticsearch and Kibana version used
for the installation (e.g. 8.14.2).

## Testing the installer

We used [bashunit](https://bashunit.typeddevs.com/) for testing the
script.

The tests are in the `/tests` folder.

To run the tests you need first to install bashunit as follows:

```bash
curl -s https://bashunit.typeddevs.com/install.sh | bash
```

This command will create a `lib` folder with the `bashunit`
command. 

You can now execute the tests using the following command:

```bash
lib/bashunit
```

The tests execute the `start-local.sh` and check if Elasticsearch
and Kibana are running. 

We also executed a local web server to test the installation
using a pipeline from an URL. To test this you need to have [PHP](https://www.php.net/)
installed.
