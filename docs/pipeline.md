# Jenkins Pipeline Reference

The `Jenkinsfile` defines a declarative pipeline with the following stages.

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `SOURCE_MODE` | choice | `volume` | `volume` = use mounted `./workspace`; `git` = clone repo |
| `GIT_REPOSITORY` | string | — | Git URL (only when `SOURCE_MODE=git`) |
| `GIT_BRANCH` | string | `main` | Branch to clone |
| `SONAR_PROJECT_KEY` | string | `external-app` | SonarQube project key |
| `DEFECTDOJO_PRODUCT_ID` | string | `1` | DefectDojo product ID |
| `DEFECTDOJO_ENGAGEMENT_ID` | string | `1` | DefectDojo engagement ID |
| `RUN_QUALYS` | boolean | `false` | Export a Qualys VM report |
| `QUALYS_REPORT_ID` | string | — | Qualys report ID to export |
| `SYNC_REDMINE` | boolean | `true` | Sync findings to Redmine |

## Stages

### 1. Source Ingestion

Populates the `src/` directory either by cloning a Git repository or copying from the mounted volume at `/workspace/external-app`.

Fails if `src/` is empty after ingestion.

### 2. Build and Unit Tests

Auto-detects the build tool in `src/`:

| Detected file | Command |
|---|---|
| `Makefile` with `test:` target | `make test` |
| `pom.xml` | `mvn -B test package` |
| `package.json` | `npm ci && npm test` |
| None | exits with code 2 |

### 3. SonarQube SAST

Runs `sonar-scanner` against `src/` and waits for the Quality Gate result.

Requires credential: `sonarqube-token`

Fails the build if the Quality Gate is not passed.

### 4. Joern CPG Analysis

Parses `src/` into a Code Property Graph (`artifacts/cpg.bin`) and runs `/opt/joern/query.sc`, writing output to `artifacts/joern-output.txt`.

Requires `joern-parse` and `joern` on the agent `PATH`.

### 5. Qualys Export _(conditional)_

Runs only when `RUN_QUALYS=true`. Calls `scripts/qualys_export.sh` to download a Qualys VM report to `artifacts/qualys/qualys-report.xml`.

Requires credential: `qualys-credentials`

### 6. DefectDojo Import

Uploads the scan file to DefectDojo via the `/api/v2/import-scan/` endpoint.

Default scan file: `artifacts/qualys/qualys-report.xml` (override with `DEFECTDOJO_SCAN_FILE`).

Requires credential: `defectdojo-api-token`

### 7. Redmine Sync _(conditional)_

Runs only when `SYNC_REDMINE=true`. Fetches active findings from DefectDojo and creates Redmine issues for any that do not already exist.

Requires credentials: `defectdojo-api-token`, `redmine-api-key`

## Artifacts

All output files are written to the `artifacts/` directory, which is bind-mounted into the Jenkins container.

| Path | Content |
|---|---|
| `artifacts/cpg.bin` | Joern Code Property Graph |
| `artifacts/joern-output.txt` | Joern query results |
| `artifacts/qualys/qualys-report.xml` | Qualys VM report |

## Integration Tests

Before triggering a pipeline run, verify all services are correctly configured:

```bash
export SONAR_TOKEN=<token>
export DEFECTDOJO_API_TOKEN=<token>
export REDMINE_API_KEY=<key>

bash tests/integration/test_pipeline.sh
bash tests/integration/test_sonarqube.sh
bash tests/integration/test_defectdojo.sh
bash tests/integration/test_redmine.sh
```

See [tests/integration/README.md](../tests/integration/README.md) for the full reference.
