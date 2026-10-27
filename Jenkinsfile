// ---------------------------------------------------------------------------
// notifyRedmineFailure: creates or updates a single Redmine ticket per
// failing stage/job. Used for non-scanner stages only. Scanner and gate
// failures are captured in the consolidated DefectDojo → Redmine ticket
// produced by Redmine Sync.
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

                    # Stable marker (no build number) so the existing ticket is
                    # updated instead of a new one being created on every failure.
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
        timeout(time: 150, unit: 'MINUTES')
    }

    parameters {
        string(name: 'GIT_REPOSITORY', defaultValue: 'https://github.com/deepak04112002/Weather-app',
               description: 'Git repository URL (leave empty to use SCM checkout)')
        string(name: 'GIT_BRANCH', defaultValue: 'main', description: 'Git branch')
        string(name: 'SONAR_PROJECT_KEY', defaultValue: 'external-app', description: 'SonarQube project key')

        booleanParam(name: 'RUN_DEPLOY', defaultValue: false,
                     description: 'Push to ECR, deploy to staging and production, run ZAP and Gate 2 (requires AWS)')

        booleanParam(name: 'RUN_QUALYS', defaultValue: false,
                     description: 'Export an existing Qualys VM report')
        string(name: 'QUALYS_REPORT_ID', defaultValue: '', description: 'Existing Qualys report ID')
        booleanParam(name: 'RUN_QUALYS_IMAGE', defaultValue: false,
                     description: 'Run Qualys QScanner image scan + SBOM (requires Qualys CS subscription)')
        booleanParam(name: 'RUN_QUALYS_WAS', defaultValue: false,
                     description: 'Run Qualys WAS DAST against staging (requires RUN_DEPLOY and Qualys WAS subscription)')

        string(name: 'AWS_ACCOUNT_ID', defaultValue: '', description: 'AWS account ID (12 digits); needed when RUN_DEPLOY is true')
        string(name: 'AWS_REGION', defaultValue: 'ap-south-1', description: 'AWS region for ECR and ECS')
        string(name: 'ECR_REPOSITORY', defaultValue: 'devsecops-weather-app', description: 'ECR repository name')

        string(name: 'STAGING_URL', defaultValue: 'http://staging:3000',
               description: 'Staging URL for OWASP ZAP and Qualys WAS')
        string(name: 'ZAP_SCAN_MINUTES', defaultValue: '30', description: 'Maximum ZAP full scan duration in minutes')

        string(name: 'ECS_CLUSTER_STAGING', defaultValue: '', description: 'ECS cluster for staging')
        string(name: 'ECS_SERVICE_STAGING', defaultValue: '', description: 'ECS service for staging')
        string(name: 'ECS_CLUSTER_PRODUCTION', defaultValue: '', description: 'ECS cluster for production')
        string(name: 'ECS_SERVICE_PRODUCTION', defaultValue: '', description: 'ECS service for production')
        string(name: 'CONTAINER_NAME', defaultValue: '', description: 'Container name inside the ECS task definition')

        booleanParam(name: 'SYNC_REDMINE', defaultValue: true, description: 'Sync active findings to Redmine')
        booleanParam(name: 'REOPEN_CLOSED_REDMINE_TICKETS', defaultValue: false,
                     description: 'Reopen the consolidated Redmine ticket if it was closed and findings are active again')
        string(name: 'REDMINE_REOPEN_STATUS_ID', defaultValue: '',
               description: 'Redmine status ID to use when reopening; required if reopening is enabled')
        string(name: 'REDMINE_CLOSED_STATUS_IDS', defaultValue: '',
               description: 'Comma-separated Redmine closed status IDs; required if reopening is enabled')
    }

    environment {
        SONAR_HOST_URL    = 'http://sonarqube:9000'
        SONAR_PROJECT_KEY = "${params.SONAR_PROJECT_KEY}"

        DEFECTDOJO_URL                   = 'http://defectdojo-nginx:8080'
        DEFECTDOJO_PRODUCT_ID            = '1'
        DEFECTDOJO_ENGAGEMENT_ID         = '1'
        DEFECTDOJO_PRODUCT_NAME          = 'DevSecOps Pipeline'
        DEFECTDOJO_ENGAGEMENT_NAME       = 'CI Pipeline'
        DEFECTDOJO_POLL_INTERVAL_SECONDS = '5'
        DEFECTDOJO_POLL_TIMEOUT_SECONDS  = '1800'
        DEFECTDOJO_LOW_BASELINE_FILE     = '/var/jenkins_home/security-baselines/defectdojo-low-findings-engagement-1.json'

        REDMINE_URL         = 'http://redmine:3000'
        REDMINE_PROJECT_ID  = '1'
        REDMINE_TRACKER_ID  = '1'
        REDMINE_STATUS_ID   = '1'
        REDMINE_PRIORITY_ID = '2'

        REDMINE_REOPEN_CLOSED     = "${params.REOPEN_CLOSED_REDMINE_TICKETS}"
        REDMINE_REOPEN_STATUS_ID  = "${params.REDMINE_REOPEN_STATUS_ID}"
        REDMINE_CLOSED_STATUS_IDS = "${params.REDMINE_CLOSED_STATUS_IDS}"

        PYTHONUNBUFFERED = '1'

        IMAGE_NAME = "devsecops-weather-app:${env.BUILD_NUMBER ?: 'latest'}"

        RUN_DEPLOY     = "${params.RUN_DEPLOY}"
        AWS_REGION     = "${params.AWS_REGION}"
        ECR_REPOSITORY = "${params.ECR_REPOSITORY}"
        ECR_REGISTRY   = "${params.AWS_ACCOUNT_ID}.dkr.ecr.${params.AWS_REGION}.amazonaws.com"

        STAGING_URL      = "${params.STAGING_URL}"
        ZAP_SCAN_MINUTES = "${params.ZAP_SCAN_MINUTES}"

        ECS_CLUSTER_STAGING    = "${params.ECS_CLUSTER_STAGING}"
        ECS_SERVICE_STAGING    = "${params.ECS_SERVICE_STAGING}"
        ECS_CLUSTER_PRODUCTION = "${params.ECS_CLUSTER_PRODUCTION}"
        ECS_SERVICE_PRODUCTION = "${params.ECS_SERVICE_PRODUCTION}"
        CONTAINER_NAME         = "${params.CONTAINER_NAME}"
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

                    if [ "$RUN_DEPLOY" = "true" ]; then
                        : "${AWS_ACCOUNT_ID:?Set AWS_ACCOUNT_ID}"
                        : "${AWS_REGION:?Set AWS_REGION}"
                        : "${ECR_REPOSITORY:?Set ECR_REPOSITORY}"
                        : "${STAGING_URL:?Set STAGING_URL}"
                        : "${ECS_CLUSTER_STAGING:?Set ECS_CLUSTER_STAGING}"
                        : "${ECS_SERVICE_STAGING:?Set ECS_SERVICE_STAGING}"
                        : "${CONTAINER_NAME:?Set CONTAINER_NAME}"

                        printf '%s' "$AWS_ACCOUNT_ID" | grep -Eq '^[0-9]{12}$' || {
                            echo "ERROR: AWS_ACCOUNT_ID must be 12 digits." >&2; exit 1; }

                        if [ "$GIT_BRANCH" = "main" ]; then
                            : "${ECS_CLUSTER_PRODUCTION:?Set ECS_CLUSTER_PRODUCTION}"
                            : "${ECS_SERVICE_PRODUCTION:?Set ECS_SERVICE_PRODUCTION}"
                        fi
                    fi

                    printf '%s' "$ZAP_SCAN_MINUTES" | grep -Eq '^[1-9][0-9]*$' || {
                        echo "ERROR: ZAP_SCAN_MINUTES must be a positive integer." >&2; exit 1; }

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

                    echo "Configuration validation passed. Deploy stages enabled: ${RUN_DEPLOY}"
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
        // 3. Gitleaks Secret Scan
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
                            export DEFECTDOJO_TEST_TITLE="Gitleaks Secret Scan"

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
            }
        }

        // -------------------------------------------------------------------
        // 4. Build and Unit Tests
        //
        // The app's Dockerfile runs the tests in a build stage, so a failing
        // test fails the docker build.
        // -------------------------------------------------------------------
        stage('Build and Unit Tests') {
            steps {
                sh '''
                    set -eu

                    if [ ! -f Dockerfile ]; then
                        echo "ERROR: No Dockerfile found in the app repo root."
                        exit 1
                    fi

                    echo "Building Docker image (includes unit tests): ${IMAGE_NAME}"
                    docker build -t "${IMAGE_NAME}" .
                    echo "Image built and unit tests passed."
                '''
            }

            post {
                failure {
                    script {
                        notifyRedmineFailure(
                            'Build and Unit Tests',
                            'Docker build or unit tests failed. Check the docker build output in the Jenkins console; a failing "npm test" step shows there.'
                        )
                    }
                }
            }
        }

        // -------------------------------------------------------------------
        // 5. Trivy Image Scan + SBOM
        // -------------------------------------------------------------------
        stage('Trivy Image Scan + SBOM') {
            steps {
                catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
                    withCredentials([
                        string(credentialsId: 'defectdojo-api-token', variable: 'DEFECTDOJO_API_TOKEN')
                    ]) {
                        sh '''
                            set -eu
                            export IMAGE_REF="${IMAGE_NAME}"
                            export IMAGE_SRC="docker"
                            export DEFECTDOJO_TEST_TITLE="Trivy Image Scan"
                            export DEFECTDOJO_TEST_ID="98"
                            export REQUIRE_DEFECTDOJO_TEST_ID="true"
                            bash /opt/devsecops/scripts/trivy_image_scan.sh
                        '''
                    }
                }
            }

            post {
                always {
                    archiveArtifacts(
                        artifacts: 'artifacts/trivy-image/**,artifacts/sbom/**',
                        allowEmptyArchive: true
                    )
                }
            }
        }

        // -------------------------------------------------------------------
        // 6. Qualys Image Scan + SBOM (optional)
        // -------------------------------------------------------------------
        stage('Qualys Image Scan + SBOM') {
            when {
                expression { params.RUN_QUALYS_IMAGE }
            }

            steps {
                catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
                    withCredentials([
                        string(credentialsId: 'defectdojo-api-token', variable: 'DEFECTDOJO_API_TOKEN'),
                        usernamePassword(
                            credentialsId: 'qualys-credentials',
                            usernameVariable: 'QUALYS_USERNAME',
                            passwordVariable: 'QUALYS_PASSWORD'
                        )
                    ]) {
                        sh '''
                            set -eu
                            export IMAGE_NAME="${IMAGE_NAME}"
                            export DEFECTDOJO_TEST_TITLE="Qualys Image Scan"
                            bash /opt/devsecops/scripts/qualys_image_scan.sh
                        '''
                    }
                }
            }

            post {
                always {
                    archiveArtifacts(
                        artifacts: 'artifacts/qualys-image/**',
                        allowEmptyArchive: true
                    )
                }
            }
        }

        // -------------------------------------------------------------------
        // 7. SonarQube SAST
        //
        // Block A: sonar-scanner and the quality gate.
        // Block B: export issues from the SonarQube API and import them into
        //          DefectDojo (test 99). Runs even if Block A failed.
        // Both blocks mark the stage FAILURE on error, so Security Gate 1
        // is the final decision point.
        // -------------------------------------------------------------------
        stage('SonarQube SAST') {
            steps {
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

                catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
                    withCredentials([
                        string(credentialsId: 'sonarqube-token',     variable: 'SONAR_TOKEN'),
                        string(credentialsId: 'defectdojo-api-token', variable: 'DEFECTDOJO_API_TOKEN')
                    ]) {
                        sh '''
                            set -eu

                            mkdir -p artifacts/sonar

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

                            export DEFECTDOJO_SCAN_FILE="artifacts/sonar/sonar-report.json"
                            export DEFECTDOJO_SCAN_TYPE="SonarQube Scan"
                            export DEFECTDOJO_TEST_TITLE="SonarQube SAST"
                            export DEFECTDOJO_TEST_ID="99"

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
            }
        }

        // -------------------------------------------------------------------
        // 8. Trivy SCA: filesystem vulnerability and secret scan
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
                            export DEFECTDOJO_TEST_ID="100"

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
            }
        }

        // -------------------------------------------------------------------
        // 9. Joern CPG Analysis
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

                                echo "Building CPG for $language..."
                                joern-parse \
                                    --language "$language" \
                                    --output   "$cpg_bin" \
                                    "$input_dir"
                                test -s "$cpg_bin" || {
                                    echo "WARNING: CPG for $language is empty — skipping queries."
                                    return 0
                                }

                                query_dir="/opt/devsecops/infra/security/joern"
                                script_lang="$language"
                                [ "$script_lang" = "rubysrc" ] && script_lang="ruby"
                                [ "$script_lang" = "newc"    ] && script_lang="c"
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
            }
        }

        // -------------------------------------------------------------------
        // 10. Qualys VM Report Import (optional)
        // -------------------------------------------------------------------
        stage('Optional Qualys VM Report Import') {
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
            }
        }

        // -------------------------------------------------------------------
        // 11. Security Gate 1: SAST / SCA / Image / Secrets
        //
        // Always runs. Fails the pipeline on any blocking finding.
        // -------------------------------------------------------------------
        stage('Security Gate 1 - SAST/SCA/Image/Secrets') {
            steps {
                script {
                    def titles = [
                        'Gitleaks Secret Scan',
                        'Trivy Image Scan',
                        'Trivy SCA',
                        'SonarQube SAST',
                        'Joern CPG Analysis'
                    ]
                    if (params.RUN_QUALYS)       { titles << 'Qualys Vulnerability Scan' }
                    if (params.RUN_QUALYS_IMAGE) { titles << 'Qualys Image Scan' }

                    env.GATE_TEST_TITLES       = titles.join(',')
                    env.GATE_BUILD_START_EPOCH = "${(currentBuild.startTimeInMillis / 1000) as long}"
                }

                withCredentials([
                    string(credentialsId: 'defectdojo-api-token', variable: 'DEFECTDOJO_API_TOKEN')
                ]) {
                    sh '''
                        set -eu
                        export GATE_NAME="gate-1"
                        bash /opt/devsecops/scripts/defectdojo_policy_gate.sh
                    '''
                }
            }
        }

        // -------------------------------------------------------------------
        // 12. Push to ECR (requires RUN_DEPLOY)
        //
        // Runs only after Gate 1. The digest is saved so staging and
        // production deploy the exact image that was scanned.
        // -------------------------------------------------------------------
        stage('Push to ECR') {
            when {
                expression { params.RUN_DEPLOY }
            }

            steps {
                withCredentials([[
                    $class: 'AmazonWebServicesCredentialsBinding',
                    credentialsId: 'aws-ecr-credentials',
                    accessKeyVariable: 'AWS_ACCESS_KEY_ID',
                    secretKeyVariable: 'AWS_SECRET_ACCESS_KEY'
                ]]) {
                    sh '''
                        set -eu
                        mkdir -p artifacts/ecr

                        sha="$(git rev-parse --short HEAD)"
                        ECR_IMAGE="${ECR_REGISTRY}/${ECR_REPOSITORY}:${BUILD_NUMBER}-${sha}"

                        aws ecr get-login-password --region "$AWS_REGION" \
                            | docker login --username AWS --password-stdin "$ECR_REGISTRY"

                        docker tag "$IMAGE_NAME" "$ECR_IMAGE"
                        docker push "$ECR_IMAGE"

                        digest="$(docker inspect --format='{{index .RepoDigests 0}}' "$ECR_IMAGE")"
                        printf '%s\n' "$digest" > artifacts/ecr/image-ref.txt
                        echo "Pushed: $digest"

                        docker logout "$ECR_REGISTRY" || true
                    '''
                }
            }

            post {
                always {
                    archiveArtifacts(
                        artifacts: 'artifacts/ecr/**',
                        allowEmptyArchive: true
                    )
                }
                failure {
                    script {
                        notifyRedmineFailure(
                            'Push to ECR',
                            'Pushing the image to ECR failed. Check AWS credentials, the ECR repository name, and Docker login output.'
                        )
                    }
                }
            }
        }

        // -------------------------------------------------------------------
        // 13. Deploy to Staging (requires RUN_DEPLOY)
        // -------------------------------------------------------------------
        stage('Deploy to Staging') {
            when {
                expression { params.RUN_DEPLOY }
            }

            steps {
                script {
                    env.ECR_IMAGE = readFile('artifacts/ecr/image-ref.txt').trim()
                }

                withCredentials([[
                    $class: 'AmazonWebServicesCredentialsBinding',
                    credentialsId: 'aws-ecr-credentials',
                    accessKeyVariable: 'AWS_ACCESS_KEY_ID',
                    secretKeyVariable: 'AWS_SECRET_ACCESS_KEY'
                ]]) {
                    sh 'bash /opt/devsecops/scripts/deploy.sh staging "$ECR_IMAGE"'
                }

                // Wait until staging responds before the DAST/PT stages start.
                sh '''
                    set -eu
                    curl --fail --silent --show-error \
                        --retry 30 --retry-delay 5 --retry-connrefused \
                        "$STAGING_URL" >/dev/null
                '''
            }

            post {
                failure {
                    script {
                        notifyRedmineFailure(
                            'Deploy to Staging',
                            'Deploying to staging failed or staging did not respond. Check the ECS service events and the deploy.sh output.'
                        )
                    }
                }
            }
        }

        // -------------------------------------------------------------------
        // 14. OWASP ZAP Penetration Test (requires RUN_DEPLOY)
        //
        // Catches scanner errors and fails the stage. Missing findings then
        // make Gate 2 fail, which is the fail-closed behavior we want.
        // -------------------------------------------------------------------
        stage('OWASP ZAP Penetration Test') {
            when {
                expression { params.RUN_DEPLOY }
            }

            steps {
                catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
                    withCredentials([
                        string(credentialsId: 'defectdojo-api-token', variable: 'DEFECTDOJO_API_TOKEN')
                    ]) {
                        sh '''
                            set -eu
                            mkdir -p artifacts/zap
                            chmod 777 artifacts/zap   # the ZAP container writes as a non-root user

                            # ZAP exit codes: 0 = pass, 1 = warnings, 2 = failures found.
                            # Anything higher is a scanner error.
                            rc=0
                            docker run --rm --network host \
                                -v "$(pwd)/artifacts/zap:/zap/wrk:rw" \
                                ghcr.io/zaproxy/zaproxy:stable \
                                zap-full-scan.py \
                                    -t "$STAGING_URL" \
                                    -m "$ZAP_SCAN_MINUTES" \
                                    -x zap-report.xml \
                                    -r zap-report.html \
                                    -I || rc=$?

                            if [ "$rc" -gt 2 ]; then
                                echo "ERROR: ZAP scanner failed (exit ${rc})." >&2
                                exit 1
                            fi

                            test -s artifacts/zap/zap-report.xml

                            export DEFECTDOJO_SCAN_FILE="artifacts/zap/zap-report.xml"
                            export DEFECTDOJO_SCAN_TYPE="ZAP Scan"
                            export DEFECTDOJO_TEST_TITLE="OWASP ZAP PT"
                            bash /opt/devsecops/scripts/defectdojo_import.sh
                        '''
                    }
                }
            }

            post {
                always {
                    archiveArtifacts(
                        artifacts: 'artifacts/zap/**',
                        allowEmptyArchive: true
                    )
                }
            }
        }

        // -------------------------------------------------------------------
        // 15. Qualys WAS DAST (requires RUN_DEPLOY and RUN_QUALYS_WAS)
        // -------------------------------------------------------------------
        stage('Qualys WAS DAST') {
            when {
                expression { params.RUN_DEPLOY && params.RUN_QUALYS_WAS }
            }

            steps {
                catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
                    withCredentials([
                        string(credentialsId: 'defectdojo-api-token', variable: 'DEFECTDOJO_API_TOKEN'),
                        usernamePassword(
                            credentialsId: 'qualys-credentials',
                            usernameVariable: 'QUALYS_USERNAME',
                            passwordVariable: 'QUALYS_PASSWORD'
                        )
                    ]) {
                        sh '''
                            set -eu
                            export WAS_TARGET_URL="$STAGING_URL"
                            export DEFECTDOJO_TEST_TITLE="Qualys WAS DAST"
                            bash /opt/devsecops/scripts/qualys_was_dast.sh
                        '''
                    }
                }
            }

            post {
                always {
                    archiveArtifacts(
                        artifacts: 'artifacts/qualys-was/**',
                        allowEmptyArchive: true
                    )
                }
            }
        }

        // -------------------------------------------------------------------
        // 16. Security Gate 2: DAST / PT (requires RUN_DEPLOY)
        // -------------------------------------------------------------------
        stage('Security Gate 2 - DAST/PT') {
            when {
                expression { params.RUN_DEPLOY }
            }

            steps {
                script {
                    def titles = ['OWASP ZAP PT']
                    if (params.RUN_QUALYS_WAS) { titles << 'Qualys WAS DAST' }

                    env.GATE_TEST_TITLES       = titles.join(',')
                    env.GATE_BUILD_START_EPOCH = "${(currentBuild.startTimeInMillis / 1000) as long}"
                }

                withCredentials([
                    string(credentialsId: 'defectdojo-api-token', variable: 'DEFECTDOJO_API_TOKEN')
                ]) {
                    sh '''
                        set -eu
                        export GATE_NAME="gate-2"
                        bash /opt/devsecops/scripts/defectdojo_policy_gate.sh
                    '''
                }
            }
        }

        // -------------------------------------------------------------------
        // 17. Deploy to Production (requires RUN_DEPLOY, manual approval)
        // -------------------------------------------------------------------
        stage('Deploy to Production') {
            when {
                expression { params.RUN_DEPLOY && params.GIT_BRANCH == 'main' }
            }

            steps {
                timeout(time: 60, unit: 'MINUTES') {
                    input message: 'Security Gates 1 and 2 passed. Deploy this image to production?',
                          ok: 'Deploy'
                }

                script {
                    env.ECR_IMAGE = readFile('artifacts/ecr/image-ref.txt').trim()
                }

                withCredentials([[
                    $class: 'AmazonWebServicesCredentialsBinding',
                    credentialsId: 'aws-ecr-credentials',
                    accessKeyVariable: 'AWS_ACCESS_KEY_ID',
                    secretKeyVariable: 'AWS_SECRET_ACCESS_KEY'
                ]]) {
                    sh 'bash /opt/devsecops/scripts/deploy.sh production "$ECR_IMAGE"'
                }
            }

            post {
                failure {
                    script {
                        notifyRedmineFailure(
                            'Deploy to Production',
                            'Production deploy failed. Check the ECS service events and the deploy.sh output.'
                        )
                    }
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Post actions. Report and Redmine sync run even when a gate fails.
    // -----------------------------------------------------------------------
    post {
        always {
            catchError(buildResult: 'UNSTABLE', stageResult: 'UNSTABLE') {
                withCredentials([
                    string(credentialsId: 'defectdojo-api-token', variable: 'DEFECTDOJO_API_TOKEN')
                ]) {
                    sh 'bash /opt/devsecops/scripts/generate_report.sh'
                }
            }

            script {
                if (params.SYNC_REDMINE) {
                    catchError(buildResult: 'UNSTABLE', stageResult: 'UNSTABLE') {
                        withCredentials([
                            string(credentialsId: 'defectdojo-api-token', variable: 'DEFECTDOJO_API_TOKEN'),
                            string(credentialsId: 'redmine-api-key',      variable: 'REDMINE_API_KEY')
                        ]) {
                            sh '/opt/devsecops/scripts/redmine_sync.sh'
                        }
                    }
                }
            }

            archiveArtifacts(
                artifacts: 'artifacts/**',
                allowEmptyArchive: true
            )
        }

        success {
            echo "Pipeline completed successfully. Build: #${env.BUILD_NUMBER}"
        }

        unstable {
            echo "Pipeline completed UNSTABLE. Build: #${env.BUILD_NUMBER}"
        }

        failure {
            echo "Pipeline FAILED. Build: #${env.BUILD_NUMBER}"
        }
    }
}