# Scripts Reference

All scripts live in `scripts/` and are bind-mounted read-only into the Jenkins container at `/opt/devsecops/scripts`.

---

## qualys_export.sh

Downloads an existing Qualys VM report by ID and saves it as XML.

### Required environment variables

| Variable | Description |
|---|---|
| `QUALYS_BASE_URL` | Qualys API base URL (e.g. `https://qualysapi.qualys.com`) |
| `QUALYS_USERNAME` | Qualys API username |
| `QUALYS_PASSWORD` | Qualys API password |
| `QUALYS_REPORT_ID` | ID of the report to download |

### Optional

| Variable | Default | Description |
|---|---|---|
| `ARTIFACTS_DIR` | `artifacts/qualys` | Output directory |

### Output

`$ARTIFACTS_DIR/qualys-report.xml`

### Failure conditions

- HTTP status other than 200
- Empty response body
- Response body is HTML (indicates an auth or API error)

---

## defectdojo_import.sh

Uploads a scan file to DefectDojo via the `/api/v2/import-scan/` REST endpoint.

### Required environment variables

| Variable | Description |
|---|---|
| `DEFECTDOJO_URL` | DefectDojo base URL |
| `DEFECTDOJO_API_TOKEN` | DefectDojo API token |
| `DEFECTDOJO_PRODUCT_ID` | Target product ID |
| `DEFECTDOJO_ENGAGEMENT_ID` | Target engagement ID |
| `DEFECTDOJO_SCAN_TYPE` | Scan type string (e.g. `Qualys Scan`) |
| `DEFECTDOJO_SCAN_FILE` | Path to the scan file to upload |

### Optional

| Variable | Default | Description |
|---|---|---|
| `DEFECTDOJO_TEST_TITLE` | `CI security scan` | Title for the test record |

### Behaviour

- Accepts HTTP 200, 201, 202 as success
- Prints a summary of the response using `jq` if available
- Exits non-zero on any other HTTP status

---

## redmine_sync.sh

Fetches active findings from DefectDojo and creates a Redmine issue for each one that does not already exist (deduplication by subject line `DD-<id>: <title>`).

### Required environment variables

| Variable | Description |
|---|---|
| `DEFECTDOJO_URL` | DefectDojo base URL |
| `DEFECTDOJO_API_TOKEN` | DefectDojo API token |
| `REDMINE_URL` | Redmine base URL |
| `REDMINE_API_KEY` | Redmine API key |
| `REDMINE_PROJECT_ID` | Target Redmine project ID |

### Optional

| Variable | Default | Description |
|---|---|---|
| `REDMINE_TRACKER_ID` | `1` | Redmine tracker ID |
| `REDMINE_STATUS_ID` | `1` | Initial issue status ID |
| `REDMINE_PRIORITY_ID` | `2` | Issue priority ID |
| `REDMINE_LIMIT` | `100` | Max findings to fetch per run |

### Dependencies

Requires `curl` and `jq` on `PATH`.

### Behaviour

- Skips findings that already have a matching Redmine issue
- Exits non-zero if Redmine issue creation returns anything other than HTTP 201
