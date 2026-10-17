# Qualys Infrastructure

Qualys is an external SaaS platform — there is no local container for it in this stack.

## How it integrates

The pipeline's **Qualys Export** stage calls `scripts/qualys_export.sh`, which authenticates to the Qualys API and downloads an existing VM report by ID.

```
Jenkins agent
    └── scripts/qualys_export.sh
            └── GET https://qualysapi.qualys.com/api/2.0/fo/report/
                    └── saves → artifacts/qualys/qualys-report.xml
```

## Required credentials (Jenkins)

| Credential ID | Kind | Fields |
|---|---|---|
| `qualys-credentials` | Username/Password | Qualys API username + password |

## Required environment variables

| Variable | Where set | Description |
|---|---|---|
| `QUALYS_BASE_URL` | `.env` | API hostname for your Qualys subscription |
| `QUALYS_REPORT_ID` | Pipeline parameter | ID of the report to download |

## Finding your API hostname

Log in to the Qualys portal → Help → About. The API URL is listed under **Qualys Platform**.

Common values:
- `https://qualysapi.qualys.com` (US Platform 1)
- `https://qualysapi.qg2.apps.qualys.com` (US Platform 2)
- `https://qualysapi.qualys.eu` (EU Platform)

## Finding a report ID

Qualys UI → Reports → VM/PC Reports → note the ID column, or use the API:

```bash
curl --user "$QUALYS_USERNAME:$QUALYS_PASSWORD" \
     --header "X-Requested-With: DevSecOps-Pipeline" \
     --get --data-urlencode "action=list" \
     "https://qualysapi.qualys.com/api/2.0/fo/report/"
```

## Integration test

```bash
export QUALYS_USERNAME=<username>
export QUALYS_PASSWORD=<password>
export QUALYS_REPORT_ID=<report_id>
bash tests/integration/test_qualys.sh
```
