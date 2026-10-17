# Integration Tests

These scripts verify that each external service the pipeline depends on is correctly configured and reachable **before** running a full pipeline build.

Run them after `task up` and before triggering a Jenkins job.

## Scripts

| Script | What it tests |
|---|---|
| `test_pipeline.sh` | All services reachable (pre-flight check) |
| `test_sonarqube.sh` | SonarQube health, token auth, project key, quality gate |
| `test_qualys.sh` | Qualys API credentials, target report ID exists |
| `test_defectdojo.sh` | DefectDojo API token, product ID, engagement ID, import endpoint |
| `test_redmine.sh` | Redmine API key, project exists, issue create/delete round-trip |

## Running all tests

```bash
# Set required variables
export SONAR_TOKEN=<sonarqube-token>
export DEFECTDOJO_API_TOKEN=<defectdojo-token>
export REDMINE_API_KEY=<redmine-api-key>
export QUALYS_USERNAME=<qualys-user>
export QUALYS_PASSWORD=<qualys-password>
export QUALYS_REPORT_ID=<report-id>

# Run each test
bash tests/integration/test_pipeline.sh
bash tests/integration/test_sonarqube.sh
bash tests/integration/test_defectdojo.sh
bash tests/integration/test_redmine.sh
bash tests/integration/test_qualys.sh   # requires Qualys credentials
```

## Running a single test

```bash
export SONAR_TOKEN=<token>
bash tests/integration/test_sonarqube.sh
```

## Environment variable reference

All scripts respect the same URL defaults as the stack. Override only if your ports differ from the defaults.

| Variable | Default |
|---|---|
| `JENKINS_URL` | `http://localhost:8080` |
| `SONAR_URL` | `http://localhost:9000` |
| `DEFECTDOJO_URL` | `http://localhost:8081` |
| `REDMINE_URL` | `http://localhost:3000` |
| `QUALYS_BASE_URL` | `https://qualysapi.qualys.com` |
| `SONAR_PROJECT_KEY` | `external-app` |
| `DEFECTDOJO_PRODUCT_ID` | `1` |
| `DEFECTDOJO_ENGAGEMENT_ID` | `1` |
| `REDMINE_PROJECT_ID` | `1` |
| `REDMINE_TRACKER_ID` | `1` |

## Exit codes

All scripts exit `0` on full pass, `1` if any check fails. Individual results are printed with `PASS` / `FAIL` prefixes.
