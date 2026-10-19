// ---------------------------------------------------------------------------
// notifyRedmineFailure — creates or updates a single Redmine ticket per
// failing stage/job. Used only for non-scanner stages (Validate Config,
// Checkout, Build, Redmine Sync) where the consolidated findings ticket
// won't exist. Scanner stage failures are captured in the consolidated
// DefectDojo → Redmine findings ticket produced by Redmine Sync.
// ---------------------------------------------------------------------------
def notifyRedmineFailure(String stageName, String details = '') {
    withCredentials([
        string(credentialsId: 'redmine-api-key', variable: 'REDMINE_API_KEY')
    ]) {
        withEnv([
            "REDMINE_FAILURE_STAGE=${stageName}",
            "REDMINE_FAILURE_DETAILS=${details}",
            "REDMINE_FAILURE_COMMIT=${env.GIT_COMMIT ?: 'Unknown'}"
        ]) {
            int notifyStatus = sh(
                returnStatus: true,
                script: '''
                    set -eu
                    set +x
                    umask 077

                    : "${REDMINE_URL:?REDMINE_URL is required}"
                    : "${REDMINE_API_KEY:?Redmine API key is required}"

                    command -v jq >/dev/null 2>&1 || {
                        echo "WARNING: jq is unavailable; cannot create Redmine notification." >&2
                        exit 1
                    }

                    command -v curl >/dev/null 2>&1 || {
                        echo "WARNING: curl is unavailable; cannot create Redmine notification." >&2
                        exit 1
                    }

                    for name in REDMINE_PROJECT_ID REDMINE_TRACKER_ID \
                                REDMINE_STATUS_ID REDMINE_PRIORITY_ID; do
                        value="$(printenv "$name" 2>/dev/null || true)"
                        if ! printf '%s' "$value" | grep -Eq '^[1-9][0-9]*$'; then
                            echo "WARNING: Invalid $name; skipping failure notification." >&2
                            exit 1
                        fi
                    done

                    tmpdir="$(mktemp -d)"
                    trap 'rm -rf "$tmpdir"' EXIT

                    stage="${REDMINE_FAILURE_STAGE:-Unknown}"
                    details="${REDMINE_FAILURE_DETAILS:-No additional details were supplied.}"
                    job="${JOB_NAME:-Unknown}"
                    build="${BUILD_NUMBER:-Unknown}"
                    commit="${REDMINE_FAILURE_COMMIT:-Unknown}"
                    url="${BUILD_URL:-Unavailable}"

                    # Stable marker (no build number) — lets us find and
                    # update the existing ticket instead of creating a new one
                    # on every failed build.
                    marker="[PIPELINE FAILURE] ${stage} - ${job}"
                    subject="${marker} #${build}"

                    existing_id=""
                    offset=0
                    page_size=100

                    while :; do
                        if ! code="$(
                            curl --silent --show-error \
                                --connect-timeout 5 --max-time 15 \
                                --header "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
                                --header "Accept: application/json" \
                                --get \
                                --data-urlencode "project_id=${REDMINE_PROJECT_ID}" \
                                --data-urlencode "status_id=*" \
                                --data-urlencode "limit=${page_size}" \
                                --data-urlencode "offset=${offset}" \
                                --output "$tmpdir/issues.json" \
                                --write-out '%{http_code}' \
                                "${REDMINE_URL%/}/issues.json"
                        )"; then
                            echo "WARNING: Redmine lookup failed; will create a new ticket." >&2
                            break
                        fi

                        if [ "$code" != "200" ]; then
                            echo "WARNING: Redmine lookup returned HTTP ${code}; will create a new ticket." >&2
                            break
                        fi

                        jq -e '(.issues | type == "array") and (.total_count | type == "number")' \
                            "$tmpdir/issues.json" >/dev/null 2>&1 || {
                            echo "WARNING: Invalid Redmine lookup response; will create a new ticket." >&2
                            break
                        }

                        total="$(jq -r '.total_count' "$tmpdir/issues.json")"
                        match="$(jq -r --arg marker "$marker" '
                            [.issues[] | select((.subject // "") | startswith($marker)) | .id]
                            | first // empty
                        ' "$tmpdir/issues.json")"

                        if [ -n "$match" ]; then
                            existing_id="$match"
                            break
                        fi

                        fetched="$(jq '.issues | length' "$tmpdir/issues.json")"
                        [ "$fetched" -gt 0 ] || break
                        offset=$((offset + fetched))
                        [ "$offset" -lt "$total" ] || break
                    done

                    if [ -n "$existing_id" ]; then
                        echo "Updating existing Redmine failure ticket #${existing_id} for stage: ${stage}"

                        note="$(printf 'Failure reoccurred in build #%s.\nGit commit: %s\nBuild URL: %s\n\nFAILURE DETAILS\n---------------\n%s' \
                            "$build" "$commit" "$url" "$details")"

                        jq -n \
                            --argjson status_id "$REDMINE_STATUS_ID" \
                            --arg subject "$subject" \
                            --arg notes "$note" \
                            '{issue: {status_id: $status_id, subject: $subject, notes: $notes}}' \
                            > "$tmpdir/update-issue.json"

                        if ! code="$(
                            curl --silent --show-error \
                                --connect-timeout 5 --max-time 15 \
                                --request PUT \
                                --header "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
                                --header "Content-Type: application/json" \
                                --header "Accept: application/json" \
                                --data @"$tmpdir/update-issue.json" \
                                --output "$tmpdir/update-response.json" \
                                --write-out '%{http_code}' \
                                "${REDMINE_URL%/}/issues/${existing_id}.json"
                        )"; then
                            echo "WARNING: Redmine update request failed." >&2
                            exit 1
                        fi

                        if [ "$code" = "200" ] || [ "$code" = "204" ]; then
                            echo "Redmine failure ticket updated: #${existing_id}"
                        else
                            echo "WARNING: Redmine update failed (HTTP ${code})." >&2
                            jq . "$tmpdir/update-response.json" >&2 2>/dev/null ||
                                cat "$tmpdir/update-response.json" >&2 || true
                            exit 1
                        fi
                        exit 0
                    fi

                    jq -n \
                        --argjson project_id "$REDMINE_PROJECT_ID" \
                        --argjson tracker_id "$REDMINE_TRACKER_ID" \
                        --argjson status_id "$REDMINE_STATUS_ID" \
                        --argjson priority_id "$REDMINE_PRIORITY_ID" \
                        --arg subject "$subject" \
                        --arg stage "$stage" \
                        --arg details "$details" \
                        --arg job "$job" \
                        --arg build "$build" \
                        --arg url "$url" \
                        --arg commit "$commit" \
                        '{
                            issue: {
                                project_id: $project_id,
                                tracker_id: $tracker_id,
                                status_id: $status_id,
                                priority_id: $priority_id,
                                subject: $subject,
                                description: (
                                    "PIPELINE FAILURE REPORT\n" +
                                    "=======================\n\n" +
                                    "Failed stage: " + $stage + "\n" +
                                    "Job: " + $job + "\n" +
                                    "Build: #" + $build + "\n" +
                                    "Git commit: " + $commit + "\n" +
                                    "Build URL: " + $url + "\n\n" +
                                    "FAILURE DETAILS\n" +
                                    "---------------\n" + $details + "\n\n" +
                                    "INVESTIGATION CHECKLIST\n" +
                                    "-----------------------\n" +
                                    "1. Open the Jenkins build URL.\n" +
                                    "2. Inspect the failed stage and console output.\n" +
                                    "3. Review the relevant scanner report or API response.\n" +
                                    "4. Correct the root cause and rerun the pipeline.\n"
                                )
                            }
                        }' > "$tmpdir/issue.json"

                    if ! code="$(
                        curl --silent --show-error \
                            --connect-timeout 5 --max-time 15 \
                            --request POST \
                            --header "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
                            --header "Content-Type: application/json" \
                            --header "Accept: application/json" \
                            --data @"$tmpdir/issue.json" \
                            --output "$tmpdir/response.json" \
                            --write-out '%{http_code}' \
                            "${REDMINE_URL%/}/issues.json"
                    )"; then
                        echo "WARNING: Redmine notification request failed." >&2
                        exit 1
                    fi

                    if [ "$code" = "201" ] &&
                       jq -e '.issue.id | numbers' "$tmpdir/response.json" >/dev/null 2>&1; then
                        issue_id="$(jq -r '.issue.id' "$tmpdir/response.json")"
                        echo "Redmine failure ticket created: #${issue_id}"
                    else
                        echo "WARNING: Redmine notification failed (HTTP ${code})." >&2
                        jq . "$tmpdir/response.json" >&2 2>/dev/null ||
                            cat "$tmpdir/response.json" >&2 || true
                        exit 1
                    fi
                '''
            )

            if (notifyStatus != 0) {
                echo "WARNING: Could not create Redmine failure ticket for stage: ${stageName}"
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Pipeline
// ---------------------------------------------------------------------------
pipeline {
    agent any

    triggers {
        githubPush()
    }

    options {
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '20'))
        timeout(time: 90, unit: 'MINUTES')
    }

    parameters {
        string(
            name: 'GIT_REPOSITORY',
            defaultValue: 'https://github.com/deepak04112002/Weather-app',
            description: 'Git repository URL (leave empty to use SCM checkout)'
        )
        string(
            name: 'GIT_BRANCH',
            defaultValue: 'main',
            description: 'Git branch'
        )
        string(
            name: 'SONAR_PROJECT_KEY',
            defaultValue: 'external-app',
            description: 'SonarQube project key'
        )
        booleanParam(
            name: 'RUN_QUALYS',
            defaultValue: false,
            description: 'Export an existing Qualys VM report'
        )
        string(
            name: 'QUALYS_REPORT_ID',
            defaultValue: '',
            description: 'Existing Qualys report ID'
        )
        booleanParam(
            name: 'SYNC_REDMINE',
            defaultValue: true,
            description: 'Sync active findings to Redmine'
        )
        booleanParam(
            name: 'REOPEN_CLOSED_REDMINE_TICKETS',
            defaultValue: false,
            description: 'Reopen the consolidated Redmine ticket if it was closed and findings are active again'
        )
        string(
            name: 'REDMINE_REOPEN_STATUS_ID',
            defaultValue: '',
            description: 'Redmine status ID to use when reopening; required if reopening is enabled'
        )
        string(
            name: 'REDMINE_CLOSED_STATUS_IDS',
            defaultValue: '',
            description: 'Comma-separated Redmine closed status IDs; required if reopening is enabled'
        )
    }

    environment {
        SONAR_HOST_URL        = 'http://sonarqube:9000'
        SONAR_PROJECT_KEY     = "${params.SONAR_PROJECT_KEY}"

        DEFECTDOJO_URL            = 'http://defectdojo-nginx:8080'
        DEFECTDOJO_PRODUCT_ID     = '1'
        DEFECTDOJO_ENGAGEMENT_ID  = '1'
        DEFECTDOJO_PRODUCT_NAME   = 'DevSecOps Pipeline'
        DEFECTDOJO_ENGAGEMENT_NAME = 'CI Pipeline'
        DEFECTDOJO_POLL_INTERVAL_SECONDS = '5'
        DEFECTDOJO_POLL_TIMEOUT_SECONDS  = '1800'
        DEFECTDOJO_LOW_BASELINE_FILE = '/var/jenkins_home/security-baselines/defectdojo-low-findings-engagement-1.json'

        REDMINE_URL        = 'http://redmine:3000'
        REDMINE_PROJECT_ID = '1'
        REDMINE_TRACKER_ID = '1'
        REDMINE_STATUS_ID  = '1'
        REDMINE_PRIORITY_ID = '2'

        REDMINE_REOPEN_CLOSED      = "${params.REOPEN_CLOSED_REDMINE_TICKETS}"
        REDMINE_REOPEN_STATUS_ID   = "${params.REDMINE_REOPEN_STATUS_ID}"
        REDMINE_CLOSED_STATUS_IDS  = "${params.REDMINE_CLOSED_STATUS_IDS}"

        PYTHONUNBUFFERED = '1'
    }

    stages {

        // -------------------------------------------------------------------
        // 1. Validate Configuration
        // -------------------------------------------------------------------
        stage('Validate Configuration') {
            steps {
                sh '''
                    set -eu

                    : "${DEFECTDOJO_URL:?Set DEFECTDOJO_URL}"
                    : "${DEFECTDOJO_PRODUCT_NAME:?Set DEFECTDOJO_PRODUCT_NAME}"
                    : "${DEFECTDOJO_ENGAGEMENT_NAME:?Set DEFECTDOJO_ENGAGEMENT_NAME}"
                    : "${REDMINE_URL:?Set REDMINE_URL}"

                    for name in REDMINE_PROJECT_ID REDMINE_TRACKER_ID \
                                REDMINE_STATUS_ID REDMINE_PRIORITY_ID; do
                        value="$(printenv "$name")"
                        if ! printf '%s' "$value" | grep -Eq '^[1-9][0-9]*$'; then
                            echo "ERROR: $name must be a positive integer." >&2
                            exit 1
                        fi
                    done

                    if [ "$REDMINE_REOPEN_CLOSED" = "true" ]; then
                        if ! printf '%s' "$REDMINE_REOPEN_STATUS_ID" |
                             grep -Eq '^[1-9][0-9]*$'; then
                            echo "ERROR: Set a valid REDMINE_REOPEN_STATUS_ID." >&2
                            exit 1
                        fi

                        if [ -z "$REDMINE_CLOSED_STATUS_IDS" ]; then
                            echo "ERROR: Set REDMINE_CLOSED_STATUS_IDS when reopening is enabled." >&2
                            exit 1
                        fi

                        old_ifs="$IFS"
                        IFS=','
                        for id in $REDMINE_CLOSED_STATUS_IDS; do
                            if ! printf '%s' "$id" | grep -Eq '^[1-9][0-9]*$'; then
                                echo "ERROR: REDMINE_CLOSED_STATUS_IDS must be comma-separated positive integers." >&2
                                exit 1
                            fi
                        done
                        IFS="$old_ifs"
                    fi

                    echo "Configuration validation passed."
                '''
            }

            post {
                failure {
                    script {
                        notifyRedmineFailure(
                            'Validate Configuration',
                            'Configuration validation failed. Review the Jenkins console for the invalid or missing setting.'
                        )
                    }
                }
            }
        }

        // -------------------------------------------------------------------
        // 2. Checkout
        // -------------------------------------------------------------------
        stage('Checkout') {
            steps {
                cleanWs()

                script {
                    if (params.GIT_REPOSITORY?.trim()) {
                        git branch: params.GIT_BRANCH,
                            credentialsId: 'github-credentials',
                            url: params.GIT_REPOSITORY
                    } else {
                        checkout scm
                    }
                }

                sh 'mkdir -p artifacts'
            }

            post {
                failure {
                    script {
                        notifyRedmineFailure(
                            'Checkout',
                            'Git checkout failed. Check the repository URL, branch name, GitHub credentials, and Jenkins network access.'
                        )
                    }
                }
            }
        }

        // -------------------------------------------------------------------
        // 3. Gitleaks Secret Scan — runs before any build or external scanner
        //
        // Scans the checked-out repository (full git history by default) for
        // committed secrets. The wrapper script produces the JSON report,
        // imports it into DefectDojo, and the Security Policy Gate fails the
        // build on any detected secret.
        // -------------------------------------------------------------------
        stage('Gitleaks Secret Scan') {
            steps {
                catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
                    withCredentials([
                        string(credentialsId: 'defectdojo-api-token', variable: 'DEFECTDOJO_API_TOKEN')
                    ]) {
                        sh '''
                            set -eu

                            export GITLEAKS_SOURCE="."
                            export GITLEAKS_REPORT_DIR="artifacts/gitleaks"

                            bash /opt/devsecops/scripts/gitleaks_scan.sh
                        '''
                    }
                }
            }

            post {
                always {
                    archiveArtifacts(
                        artifacts: 'artifacts/gitleaks/**',
                        allowEmptyArchive: true
                    )
                }
                // No notifyRedmineFailure — findings are captured in the
                // consolidated Redmine Sync ticket.
            }
        }

        // -------------------------------------------------------------------
        // 4. Build and Unit Tests
        // -------------------------------------------------------------------
        stage('Build and Unit Tests') {
            steps {
                sh '''
                    set -eu

                    if [ -f Makefile ] && grep -qE '^[[:space:]]*test:' Makefile; then
                        make test
                    elif [ -f pom.xml ]; then
                        mvn -B test package
                    elif [ -f package.json ]; then
                        npm ci
                        npm test
                    else
                        echo "No supported build file detected (Makefile / pom.xml / package.json)."
                        echo "Add the application build and test commands."
                        exit 2
                    fi
                '''
            }

            post {
                failure {
                    script {
                        notifyRedmineFailure(
                            'Build and Unit Tests',
                            'Build or unit tests failed. Review the build-tool output, dependency installation, and test failures in the Jenkins console.'
                        )
                    }
                }
            }
        }

        // -------------------------------------------------------------------
        // 5. SonarQube SAST
        //
        // Two independent catchError blocks so the two failure modes are
        // distinguished clearly:
        //
        //   Block A – sonar-scanner / quality gate
        //     Quality gate fail  → build UNSTABLE  (code-quality warning,
        //                          does NOT block downstream stages)
        //     Scanner crash      → build UNSTABLE  (same treatment; the
        //                          DefectDojo import may still succeed with
        //                          whatever issues were already uploaded)
        //
        //   Block B – SonarQube API export + DefectDojo import
        //     Import fail        → build FAILURE   (real infra problem;
        //                          findings didn't reach DefectDojo)
        //     Always runs even when Block A marks the stage failed.
        // -------------------------------------------------------------------
        stage('SonarQube SAST') {
            steps {
                // Block A: run the scanner; quality-gate failure → UNSTABLE
                catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
                    withCredentials([
                        string(credentialsId: 'sonarqube-token', variable: 'SONAR_TOKEN')
                    ]) {
                        sh '''
                            set -eu

                            sonar-scanner \
                                -Dsonar.projectKey="$SONAR_PROJECT_KEY" \
                                -Dsonar.projectName="$SONAR_PROJECT_KEY" \
                                -Dsonar.sources=. \
                                -Dsonar.host.url="$SONAR_HOST_URL" \
                                -Dsonar.token="$SONAR_TOKEN" \
                                -Dsonar.qualitygate.wait=true
                        '''
                    }
                }

                // Block B: export issues from SonarQube API and import to
                // DefectDojo. Runs regardless of Block A outcome.
                catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
                    withCredentials([
                        string(credentialsId: 'sonarqube-token',    variable: 'SONAR_TOKEN'),
                        string(credentialsId: 'defectdojo-api-token', variable: 'DEFECTDOJO_API_TOKEN')
                    ]) {
                        sh '''
                            set -eu

                            mkdir -p artifacts/sonar

                            # ---- Paginate the SonarQube issues API ----
                            page=1
                            total_pages=1
                            all_issues="[]"

                            while [ "$page" -le "$total_pages" ]; do
                                response="$(
                                    curl --fail --silent --show-error \
                                        --connect-timeout 10 --max-time 60 \
                                        --header "Authorization: Bearer ${SONAR_TOKEN}" \
                                        --get \
                                        --data-urlencode "componentKeys=${SONAR_PROJECT_KEY}" \
                                        --data-urlencode "resolved=false" \
                                        --data-urlencode "ps=500" \
                                        --data-urlencode "p=${page}" \
                                        --data-urlencode "additionalFields=_all" \
                                        "${SONAR_HOST_URL}/api/issues/search"
                                )"

                                echo "$response" | \
                                    jq -e '(.issues | type == "array") and (.total | type == "number")' \
                                    >/dev/null

                                total="$(echo "$response" | jq -r '.total')"
                                total_pages=$(( (total + 499) / 500 ))

                                issues="$(echo "$response" | jq '.issues')"
                                all_issues="$(
                                    jq -n \
                                        --argjson a "$all_issues" \
                                        --argjson b "$issues" \
                                        '$a + $b'
                                )"

                                page=$((page + 1))
                            done

                            jq -n \
                                --argjson issues "$all_issues" \
                                '{
                                    issues: $issues,
                                    total:  ($issues | length),
                                    p:  1,
                                    ps: ($issues | length)
                                }' > artifacts/sonar/sonar-report.json

                            test -s artifacts/sonar/sonar-report.json

                            # ---- Import into DefectDojo ----
                            export DEFECTDOJO_SCAN_FILE="artifacts/sonar/sonar-report.json"
                            export DEFECTDOJO_SCAN_TYPE="SonarQube Scan"
                            export DEFECTDOJO_TEST_TITLE="SonarQube SAST"

                            bash /opt/devsecops/scripts/defectdojo_import.sh
                        '''
                    }
                }
            }

            post {
                always {
                    archiveArtifacts(
                        artifacts: 'artifacts/sonar/**',
                        allowEmptyArchive: true
                    )
                }
                // No notifyRedmineFailure — scanner findings are
                // captured in the consolidated Redmine Sync ticket.
            }
        }

        // -------------------------------------------------------------------
        // 6. Trivy SCA — filesystem vulnerability + secret scan → DefectDojo
        // -------------------------------------------------------------------
        stage('Trivy SCA') {
            steps {
                catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
                    withCredentials([
                        string(credentialsId: 'defectdojo-api-token', variable: 'DEFECTDOJO_API_TOKEN')
                    ]) {
                        sh '''
                            set -eu

                            mkdir -p artifacts/trivy

                            trivy fs \
                                --exit-code 0 \
                                --format json \
                                --output artifacts/trivy/trivy-report.json \
                                --scanners vuln,secret \
                                --skip-dirs .git,node_modules,artifacts \
                                .

                            export DEFECTDOJO_SCAN_FILE="artifacts/trivy/trivy-report.json"
                            export DEFECTDOJO_SCAN_TYPE="Trivy Scan"
                            export DEFECTDOJO_TEST_TITLE="Trivy SCA"

                            bash /opt/devsecops/scripts/defectdojo_import.sh
                        '''
                    }
                }
            }

            post {
                always {
                    archiveArtifacts(
                        artifacts: 'artifacts/trivy/**',
                        allowEmptyArchive: true
                    )
                }
                // No notifyRedmineFailure — captured in consolidated ticket.
            }
        }

        // -------------------------------------------------------------------
        // 7. Joern CPG Analysis — code property graph SAST → DefectDojo
        //
        // Three steps per language:
        //   a. joern-parse  — build the CPG (.bin) from source files
        //   b. joern --script query.sc  — run security queries against the
        //      CPG and write *-results.json into artifacts/joern/
        //   c. joern_import.sh  — convert result files to Generic Findings
        //      Import format and push to DefectDojo
        // -------------------------------------------------------------------
        stage('Joern CPG Analysis') {
            steps {
                catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
                    withCredentials([
                        string(credentialsId: 'defectdojo-api-token', variable: 'DEFECTDOJO_API_TOKEN')
                    ]) {
                        sh '''
                            set -eu

                            mkdir -p artifacts/joern
                            command -v joern-parse >/dev/null
                            command -v joern       >/dev/null

                            find . -type d \\( \
                                -name node_modules -o \
                                -name .git         -o \
                                -name target       -o \
                                -name build        -o \
                                -name dist         -o \
                                -name artifacts    \
                            \\) -prune -o -type f -print \
                                > artifacts/joern/source-files.txt

                            # -------------------------------------------------
                            # run_parser: build CPG then run security queries
                            # -------------------------------------------------
                            run_parser() {
                                language="$1"
                                pattern="$2"
                                cpg_bin="artifacts/joern/${language}-cpg.bin"
                                filelist="artifacts/joern/${language}-files.txt"
                                results_file="artifacts/joern/${language}-results.json"

                                grep -Ei "$pattern" artifacts/joern/source-files.txt \
                                    > "$filelist" || true

                                if [ ! -s "$filelist" ]; then
                                    echo "Skipping $language: no matching files."
                                    return 0
                                fi

                                input_dir="artifacts/joern/input-${language}"
                                mkdir -p "$input_dir"

                                while IFS= read -r file; do
                                    [ -f "$file" ] || continue
                                    relative="${file#./}"
                                    mkdir -p "$input_dir/$(dirname "$relative")"
                                    cp "$file" "$input_dir/$relative"
                                done < "$filelist"

                                if ! find "$input_dir" -type f -print -quit | grep -q .; then
                                    echo "No files staged for $language — skipping."
                                    return 0
                                fi

                                # Step a: build CPG
                                echo "Building CPG for $language..."
                                joern-parse \
                                    --language "$language" \
                                    --output   "$cpg_bin" \
                                    "$input_dir"
                                test -s "$cpg_bin" || {
                                    echo "WARNING: CPG for $language is empty — skipping queries."
                                    return 0
                                }

                                # Step b: pick language-specific script, fall back to generic
                                query_dir="/opt/devsecops/infra/security/joern"
                                # rubysrc language uses the ruby script
                                script_lang="$language"
                                [ "$script_lang" = "rubysrc" ] && script_lang="ruby"
                                # newc (C++) reuses the c script
                                [ "$script_lang" = "newc"    ] && script_lang="c"
                                # kotlin reuses the java CPG model but has its own script
                                query_script="${query_dir}/query_${script_lang}.sc"
                                if [ ! -f "$query_script" ]; then
                                    echo "No specific query script for $language — using generic."
                                    query_script="${query_dir}/query_generic.sc"
                                fi

                                echo "Running security queries on $language CPG (${query_script##*/})..."
                                joern --script "$query_script" \
                                    --param "cpgFile=$(pwd)/${cpg_bin}" \
                                    --param "outFile=$(pwd)/${results_file}" \
                                    || echo "WARNING: Joern query script exited non-zero for $language."

                                if [ -s "$results_file" ]; then
                                    echo "$language: query results written to $results_file"
                                else
                                    echo "$language: no findings from queries."
                                fi
                            }

                            run_parser javascript  '\\.(js|jsx|mjs|cjs)$'
                            run_parser python      '\\.py$'
                            run_parser java        '\\.java$'
                            run_parser kotlin      '\\.kt$'
                            run_parser golang      '\\.go$'
                            run_parser csharp      '\\.cs$'
                            run_parser php         '\\.php$'
                            run_parser rubysrc     '\\.rb$'
                            run_parser c           '\\.c$'
                            run_parser newc        '\\.(cc|cpp|cxx|h|hpp|hh|hxx)$'
                            run_parser rust        '\\.rs$'
                            run_parser swift       '\\.swift$'
                            run_parser abap        '\\.abap$'

                            # Step c: import all result files into DefectDojo
                            export DEFECTDOJO_TEST_TITLE="Joern CPG Analysis"
                            bash /opt/devsecops/scripts/joern_import.sh
                        '''
                    }
                }
            }

            post {
                always {
                    archiveArtifacts(
                        artifacts: 'artifacts/joern/**',
                        allowEmptyArchive: true
                    )
                }
                // No notifyRedmineFailure — captured in consolidated ticket.
            }
        }

        // -------------------------------------------------------------------
        // 8. Qualys Export (optional) — VM scan report → DefectDojo
        // -------------------------------------------------------------------
        stage('Qualys Export') {
            when {
                expression { params.RUN_QUALYS }
            }

            steps {
                catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
                    withCredentials([
                        usernamePassword(
                            credentialsId: 'qualys-credentials',
                            usernameVariable: 'QUALYS_USERNAME',
                            passwordVariable: 'QUALYS_PASSWORD'
                        ),
                        string(credentialsId: 'defectdojo-api-token', variable: 'DEFECTDOJO_API_TOKEN')
                    ]) {
                        sh '''
                            set -eu

                            mkdir -p artifacts/qualys
                            export QUALYS_REPORT_ID="${QUALYS_REPORT_ID:-}"

                            /opt/devsecops/scripts/qualys_export.sh

                            export DEFECTDOJO_SCAN_FILE="artifacts/qualys/qualys-report.xml"
                            export DEFECTDOJO_SCAN_TYPE="Qualys Scan"
                            export DEFECTDOJO_TEST_TITLE="Qualys Vulnerability Scan"

                            bash /opt/devsecops/scripts/defectdojo_import.sh
                        '''
                    }
                }
            }

            post {
                always {
                    archiveArtifacts(
                        artifacts: 'artifacts/qualys/**',
                        allowEmptyArchive: true
                    )
                }
                // No notifyRedmineFailure — captured in consolidated ticket.
            }
        }

        // -------------------------------------------------------------------
        // 9. Security Report (PDF)
        //
        // Fetches all active DefectDojo findings, builds a styled HTML report
        // grouped by severity and scanner, then converts it to PDF via
        // weasyprint. The PDF is archived as a Jenkins artifact.
        // Stage failure is non-blocking (catchError UNSTABLE) so a missing
        // weasyprint or rendering issue never breaks the pipeline.
        // -------------------------------------------------------------------
        stage('Security Report (PDF)') {
            steps {
                catchError(buildResult: 'UNSTABLE', stageResult: 'UNSTABLE') {
                    withCredentials([
                        string(credentialsId: 'defectdojo-api-token', variable: 'DEFECTDOJO_API_TOKEN')
                    ]) {
                        sh 'bash /opt/devsecops/scripts/generate_report.sh'
                    }
                }
            }

            post {
                always {
                    archiveArtifacts(
                        artifacts: 'artifacts/report/**',
                        allowEmptyArchive: true
                    )
                }
            }
        }

        // -------------------------------------------------------------------
        // 10. Redmine Sync
        //
        // Pulls every active finding from DefectDojo (all scanners combined),
        // builds a consolidated report grouped by scanner and severity, then
        // creates or updates a single Redmine ticket for this job.
        //
        // First run  → ticket created.
        // Later runs → same ticket updated: description replaced with the
        //              latest full report; a short per-build summary appended
        //              as a note (running history).
        // -------------------------------------------------------------------
        stage('Redmine Sync') {
            when {
                expression { params.SYNC_REDMINE }
            }

            steps {
                withCredentials([
                    string(credentialsId: 'defectdojo-api-token', variable: 'DEFECTDOJO_API_TOKEN'),
                    string(credentialsId: 'redmine-api-key',       variable: 'REDMINE_API_KEY')
                ]) {
                    sh '/opt/devsecops/scripts/redmine_sync.sh'
                }
            }

            post {
                failure {
                    script {
                        notifyRedmineFailure(
                            'Redmine Sync',
                            'The DefectDojo-to-Redmine sync failed. Review the Redmine API response and redmine_sync.sh console output.'
                        )
                    }
                }
            }
        }

        // -------------------------------------------------------------------
        // 11. Security Policy Gate
        //
        // Checks findings from all scanners in DefectDojo and decides whether
        // the build passes or fails, instead of relying only on Trivy's exit
        // code.
        //
        // Policy:
        // - CRITICAL, HIGH, or MEDIUM findings: fail immediately.
        // - Any detected secret (Gitleaks or Trivy): fail immediately.
        // - New LOW vulnerability: pass and record it.
        // - Previously seen LOW vulnerability found again in a later build: fail.
        // - Scan or DefectDojo import failure: fail.
        // -------------------------------------------------------------------
        stage('Security Policy Gate') {
            steps {
                withCredentials([
                    string(
                        credentialsId: 'defectdojo-api-token',
                        variable: 'DEFECTDOJO_API_TOKEN'
                    )
                ]) {
                    sh 'bash /opt/devsecops/scripts/defectdojo_policy_gate.sh'
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Global post actions
    // -----------------------------------------------------------------------
    post {
        success {
            echo "Pipeline completed successfully. Build: #${env.BUILD_NUMBER}"
        }

        unstable {
            echo "Pipeline completed UNSTABLE (SonarQube quality gate). Build: #${env.BUILD_NUMBER}"
        }

        failure {
            echo "Pipeline FAILED. Build: #${env.BUILD_NUMBER}"
        }

        always {
            archiveArtifacts(
                artifacts: 'artifacts/**',
                allowEmptyArchive: true
            )
        }
    }
}