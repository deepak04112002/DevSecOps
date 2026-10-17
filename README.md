# DevSecOps Lab

A self-contained, locally-hosted DevSecOps pipeline that integrates static analysis, vulnerability management, and issue tracking into a single Docker Compose stack.

## Stack

| Service | Role | Default Port |
|---|---|---|
| Jenkins | CI/CD orchestration | 8080 |
| SonarQube | SAST / code quality | 9000 |
| DefectDojo | Vulnerability management | 8081 |
| Redmine | Issue tracking | 3000 |
| Joern | Code Property Graph analysis | on-demand |

## Quick Start

```bash
# 1. Copy and edit environment variables
cp .env.example .env
# Edit .env — set all CHANGE_ME_* values before proceeding

# 2. Create required directories
task init

# 3. Build images and start the stack
task up

# 4. Verify services are healthy
task ps
```

> Jenkins is available at http://localhost:8080 after startup completes (~2 min).

## Documentation

| Doc | Description |
|---|---|
| [docs/setup.md](docs/setup.md) | First-time setup and credential configuration |
| [docs/pipeline.md](docs/pipeline.md) | Jenkins pipeline stages reference |
| [docs/services.md](docs/services.md) | Service architecture and networking |
| [docs/scripts.md](docs/scripts.md) | Shell script reference |
| [docs/joern.md](docs/joern.md) | Joern CPG analysis guide |
| [docs/smoke-test.md](docs/smoke-test.md) | Staging smoke test usage |

## Requirements

- Docker Engine 24+
- Docker Compose v2
- [Task](https://taskfile.dev) (optional but recommended)

## Security Notes

- All services bind to `127.0.0.1` only — never expose ports publicly.
- The Docker socket is **not** mounted into Jenkins.
- Rotate all `CHANGE_ME_*` secrets before first use.
- See [docs/setup.md](docs/setup.md) for credential setup in Jenkins.
