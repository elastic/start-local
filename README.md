# 🚀 Try Elasticsearch and Kibana locally

Run Elasticsearch and Kibana on your local machine using a simple shell script. This setup uses [Docker](https://www.docker.com/) behind the scenes to install and run the services.

> [!IMPORTANT]  
> This script is for local testing only. Do not use it in production!
> For production installations refer to the official documentation for [Elasticsearch](https://www.elastic.co/downloads/elasticsearch) and [Kibana](https://www.elastic.co/downloads/kibana).

## 🌟 Features

This script comes with a one-month trial license.
After the trial period, the license reverts to [Free and open - Basic](https://www.elastic.co/subscriptions).

- **Trial**: Includes **All** features like the [Playground](https://www.elastic.co/docs/current/serverless/elasticsearch/playground), [ELSER](https://www.elastic.co/guide/en/machine-learning/current/ml-nlp-elser.html), [semantic retrieval model](https://www.elastic.co/guide/en/machine-learning/8.15/ml-nlp-text-emb-vector-search-example.html), the [Elastic Inference API](https://www.elastic.co/guide/en/elasticsearch/reference/current/inference-apis.html) and much more.
- **Free and open - Basic**: Includes features like [vector search](https://www.elastic.co/what-is/vector-search), [ES|QL](https://www.elastic.co/guide/en/elasticsearch/reference/current/esql.html) and much more.

For a complete list of subscriptions and features, see our [subscriptions page](https://www.elastic.co/subscriptions).

## 💻 System requirements

- [Docker](https://www.docker.com/)
- Works on Linux and macOS
- On Microsoft Windows it works using [Windows Subsystem for Linux (WSL)](https://learn.microsoft.com/en-us/windows/wsl/install)

## 🏃‍♀️‍➡️ Getting started

### Setup

Run the `start-local` script using [curl](https://curl.se/):

```bash
curl -fsSL https://elastic.co/start-local | sh
```

This script creates an `elastic-start-local` folder containing:
- `docker-compose.yml`: Docker Compose configuration for Elasticsearch and Kibana
- `.env`: Environment settings, including the Elasticsearch password
- `start.sh` and `stop.sh`: Scripts to start and stop Elasticsearch and Kibana
- `uninstall.sh`: The script to uninstall Elasticsearch and Kibana

### 🌐 Endpoints

After running the script:
- Elasticsearch will be running at http://localhost:9200
- Kibana will be running at http://localhost:5601

The script generates a random password for the `elastic` user, displayed at the end of the installation and stored in the `.env` file.

> [!CAUTION]
> HTTPS is disabled, and Basic authentication is used for Elasticsearch. This configuration is for local testing only. For security, Elasticsearch and Kibana are accessible only via `localhost`.

### 🔑 API key

An API key for Elasticsearch is generated and stored in the `.env` file as `ES_LOCAL_API_KEY`. Use this key to connect to Elasticsearch with the [Elastic SDK](https://www.elastic.co/guide/en/elasticsearch/client) or [REST API](https://www.elastic.co/guide/en/elasticsearch/reference/current/rest-apis.html).

Check the connection to Elasticsearch using `curl` in the `elastic-start-local` folder:

```bash
source .env
curl $ES_LOCAL_URL -H "Authorization: ApiKey ${ES_LOCAL_API_KEY}"
```

## 🐳 Start and stop the services

You can use the `start` and `stop` commands available in the `elastic-start-local` folder.

To **stop** the Elasticsearch and Kibana Docker services, use the `stop` command:

```bash
cd elastic-start-local
./stop.sh
```

To **start** the Elasticsearch and Kibana Docker services, use the `start` command:

```bash
cd elastic-start-local
./start.sh
```

[Docker Compose](https://docs.docker.com/reference/cli/docker/compose/).

## 🗑️ Uninstallation

To remove the `start-local` installation:

```bash
cd elastic-start-local
./uninstall.sh
```

> [!WARNING]  
> This erases all data permanently.

## 📝 Logging

If the installation fails, an error log is created in `error-start-local.log`. This file contains logs from Elasticsearch and Kibana, captured using the [docker logs](https://docs.docker.com/reference/cli/docker/container/logs/) command.

## ⚙️ Customizing settings

To change settings (e.g., Elasticsearch password), edit the `.env` file. Example contents:

```bash
ES_LOCAL_VERSION=8.15.2
ES_LOCAL_URL=http://localhost:9200
ES_LOCAL_CONTAINER_NAME=es-local-dev
ES_LOCAL_DOCKER_NETWORK=elastic-net
ES_LOCAL_PASSWORD=hOalVFrN
ES_LOCAL_PORT=9200
KIBANA_LOCAL_CONTAINER_NAME=kibana-local-dev
KIBANA_LOCAL_PORT=5601
KIBANA_LOCAL_PASSWORD=YJFbhLJL
ES_LOCAL_API_KEY=df34grtk...==
```

> [!IMPORTANT]
> After changing the `.env` file, restart the services using `stop` and `start`:
> ```bash
> cd elastic-start-local
> ./stop.sh
> ./start.sh
> ```

## 🧪 Testing the installer

We use [bashunit](https://bashunit.typeddevs.com/) to test the script. Tests are in the `/tests` folder.

### Running tests

1. Install bashunit:
   ```bash
   curl -s https://bashunit.typeddevs.com/install.sh | bash
   ```

2. Run tests:
   ```bash
   lib/bashunit
   ```

The tests run `start-local.sh` and check if Elasticsearch and Kibana are working.

> [!NOTE]
> For URL pipeline testing, a local web server is used. This requires [PHP](https://www.php.net/).
