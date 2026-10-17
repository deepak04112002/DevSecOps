# Service Architecture

## Network Topology

```
Host (127.0.0.1 only)
│
├── :8080  jenkins       ──── ci, security networks
├── :9000  sonarqube     ──── security, sonar_db_net
├── :8081  defectdojo    ──── security, dojo_db_net
└── :3000  redmine       ──── security, redmine_db_net

Internal-only (no host port):
  sonar-db      ── sonar_db_net
  dojo-db       ── dojo_db_net
  dojo-redis    ── dojo_db_net
  dojo-worker   ── dojo_db_net   (profile: defectdojo-worker)
  redmine-db    ── redmine_db_net

On-demand (profiles):
  joern         ── security      (profile: analysis)
  smoke         ── security      (profile: tools)
```

## Networks

| Network | Purpose |
|---|---|
| `ci` | Jenkins outbound access |
| `security` | Inter-service communication (Jenkins ↔ SonarQube, DefectDojo, Redmine) |
| `sonar_db_net` | SonarQube ↔ PostgreSQL (internal) |
| `dojo_db_net` | DefectDojo ↔ PostgreSQL + Redis (internal) |
| `redmine_db_net` | Redmine ↔ PostgreSQL (internal) |

All database networks are marked `internal: true` — no external routing.

## Services

### jenkins

- Image: built from `infra/jenkins/Dockerfile` (Jenkins LTS + JDK 21 + sonar-scanner)
- CasC config: `infra/jenkins/casc/jenkins.yaml`
- Volumes: `jenkins_home`, `./workspace` (read-only), `./artifacts`, `./scripts` (read-only)
- Depends on: `sonarqube` (healthy)

### sonarqube

- Image: `sonarqube:lts-community`
- Healthcheck: polls `/api/system/status` every 20 s, up to 20 retries with a 90 s start period
- Depends on: `sonar-db` (healthy)

### sonar-db

- Image: `postgres:16`
- Healthcheck: `pg_isready -U sonar -d sonar`

### defectdojo

- Image: `defectdojo/defectdojo-django:latest`
- Depends on: `dojo-db` (healthy), `dojo-redis` (healthy)

> Pin this image to a specific release tag for production use.

### dojo-worker

- Same image as `defectdojo`, runs the Celery worker
- Profile: `defectdojo-worker` — start with `docker compose --profile defectdojo-worker up -d`

### dojo-db / dojo-redis

- PostgreSQL 16 and Redis 7 (Alpine) for DefectDojo

### redmine

- Image: `redmine:6`
- Depends on: `redmine-db` (healthy)

### redmine-db

- Image: `postgres:16`

### joern _(on-demand)_

- Image: built from `infra/security/joern/Dockerfile`
- Profile: `analysis`
- Run: `task joern` or `docker compose --profile analysis run --rm joern`

### smoke _(on-demand)_

- Image: `curlimages/curl:8.10.1`
- Profile: `tools`
- Run: `task smoke` or `docker compose --profile tools run --rm smoke`

## Volumes

| Volume | Used by |
|---|---|
| `jenkins_home` | Jenkins |
| `sonar_data` / `sonar_extensions` / `sonar_logs` | SonarQube |
| `sonar_db_data` | sonar-db |
| `dojo_db_data` | dojo-db |
| `dojo_redis_data` | dojo-redis |
| `redmine_db_data` | redmine-db |
| `redmine_files` | Redmine |
