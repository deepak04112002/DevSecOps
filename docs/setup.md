# Setup Guide

## Prerequisites

- Docker Engine 24+
- Docker Compose v2 (`docker compose version`)
- [Task](https://taskfile.dev) — install via `sh -c "$(curl --location https://taskfile.dev/install.sh)" -- -d -b /usr/local/bin`

## 1. Environment File

```bash
cp .env.example .env
```

Open `.env` and replace every `CHANGE_ME_*` value:

| Variable | Description |
|---|---|
| `SONAR_DB_PASSWORD` | PostgreSQL password for SonarQube |
| `DD_DB_PASSWORD` | PostgreSQL password for DefectDojo |
| `DD_SECRET_KEY` | Long random secret for DefectDojo Django |
| `REDMINE_DB_PASSWORD` | PostgreSQL password for Redmine |

Generate strong secrets:
```bash
openssl rand -base64 32
```

## 2. Start the Stack

```bash
task init   # creates workspace/, artifacts/, secrets/
task up     # builds images and starts all services
task ps     # verify all containers are healthy
```

## 3. Jenkins First-Run

1. Open http://localhost:8080
2. Complete the setup wizard (or skip if CasC pre-configures it).
3. Install recommended plugins if prompted.

## 4. Jenkins Credentials

Navigate to **Manage Jenkins → Credentials → System → Global** and add:

| ID | Kind | Description |
|---|---|---|
| `sonarqube-token` | Secret text | SonarQube user token |
| `defectdojo-api-token` | Secret text | DefectDojo API key |
| `redmine-api-key` | Secret text | Redmine API key |
| `qualys-credentials` | Username/Password | Qualys API username + password |

### Getting each token

**SonarQube** — http://localhost:9000 → My Account → Security → Generate Token

**DefectDojo** — http://localhost:8081 → Profile → API v2 Key

**Redmine** — http://localhost:3000 → My Account → API access key

## 5. Jenkins Agent

The pipeline requires a node labelled `devsecops-agent`. Add a permanent agent or configure an inbound agent with that label in **Manage Jenkins → Nodes**.

## 6. Application Source

Place the application source you want to scan in `./workspace/` (or set `APP_SOURCE_HOST_PATH` in `.env` to an absolute path).

## Stopping the Stack

```bash
task down        # stop, keep volumes
task down-wipe   # stop and delete all data (irreversible)
```
