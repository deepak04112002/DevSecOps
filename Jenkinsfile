
def notifyRedmineFailure(String stageName, String details = '') {
    withCredentials([
        string(credentialsId: 'redmine-api-key', variable: 'REDMINE_API_KEY')
    ]) {
        withEnv([
            "REDMINE_FAILURE_STAGE=${stageName}",
            "REDMINE_FAILURE_DETAILS=${details}"
        ]) {
            sh '''
                set -eu
                set +x
                umask 077

                : "${REDMINE_URL:?REDMINE_URL is required}"
                : "${REDMINE_PROJECT_ID:?REDMINE_PROJECT_ID is required}"
                : "${REDMINE_TRACKER_ID:?REDMINE_TRACKER_ID is required}"
                : "${REDMINE_STATUS_ID:?REDMINE_STATUS_ID is required}"
                : "${REDMINE_PRIORITY_ID:?REDMINE_PRIORITY_ID is required}"
                : "${REDMINE_API_KEY:?Redmine API key is required}"

                command -v jq >/dev/null
                command -v curl >/dev/null

                tmpdir="$(mktemp -d)"
                trap 'rm -rf "$tmpdir"' EXIT

                for name in REDMINE_PROJECT_ID REDMINE_TRACKER_ID \
                            REDMINE_STATUS_ID REDMINE_PRIORITY_ID; do
                    value="$(printenv "$name")"
                    if ! printf '%s' "$value" | grep -Eq '^[1-9][0-9]*$'; then
                        echo "ERROR: Invalid $name" >&2
                        exit 1
                    fi
                done

                jq -n \
                    --argjson project_id "$REDMINE_PROJECT_ID" \
                    --argjson tracker_id "$REDMINE_TRACKER_ID" \
                    --argjson status_id "$REDMINE_STATUS_ID" \
                    --argjson priority_id "$REDMINE_PRIORITY_ID" \
                    --arg stage "${REDMINE_FAILURE_STAGE:-Unknown}" \
                    --arg details "${REDMINE_FAILURE_DETAILS:-}" \
                    --arg job "${JOB_NAME:-Unknown}" \
                    --arg build "${BUILD_NUMBER:-Unknown}" \
                    --arg url "${BUILD_URL:-}" \
                    '{
                        issue: {
                            project_id: $project_id,
                            tracker_id: $tracker_id,
                            status_id: $status_id,
                            priority_id: $priority_id,
                            subject: (
                                "[PIPELINE FAILURE] " + $stage +
                                " - " + $job + " #" + $build
                            ),
                            description: (
                                "Stage: " + $stage + "\n" +
                                (if $details == "" then "" else
                                    $details + "\n"
                                end) +
                                "Job: " + $job + "\n" +
                                "Build: #" + $build + "\n" +
                                "URL: " + $url
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
                    echo "WARNING: Redmine failure notification request failed." >&2
                    exit 0
                fi

                if [ "$code" = "201" ] &&
                   jq -e '.issue.id | numbers' "$tmpdir/response.json" >/dev/null 2>&1; then
                    echo "Redmine failure notification created."
                else
                    echo "WARNING: Redmine notification failed (HTTP $code)." >&2
                    jq . "$tmpdir/response.json" >&2 2>/dev/null ||
                        cat "$tmpdir/response.json" >&2 || true
                fi
            '''
        }
    }
}

pipeline {
    agent {
        label 'devsecops-agent'
    }

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
        string(
            name: 'DEFECTDOJO_PRODUCT_ID',
            defaultValue: '1',
            description: 'Existing DefectDojo product ID'
        )
        string(
            name: 'DEFECTDOJO_ENGAGEMENT_ID',
            defaultValue: '1',
            description: 'Existing DefectDojo engagement ID'
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
            description: 'Reopen matching closed Redmine tickets when findings are active again'
        )
        string(
            name: 'REDMINE_REOPEN_STATUS_ID',
            defaultValue: '',
            description: 'Redmine status ID to use when reopening tickets; required if reopening is enabled'
        )
        string(
            name: 'REDMINE_CLOSED_STATUS_IDS',
            defaultValue: '',
            description: 'Comma-separated Redmine closed status IDs; required if reopening is enabled'
        )
    }

    environment {
        SONAR_HOST_URL = 'http://sonarqube:9000'
        SONAR_PROJECT_KEY = "${params.SONAR_PROJECT_KEY}"

        DEFECTDOJO_URL = 'http://defectdojo-nginx:8080'
        DEFECTDOJO_PRODUCT_ID = "${params.DEFECTDOJO_PRODUCT_ID}"
        DEFECTDOJO_ENGAGEMENT_ID = "${params.DEFECTDOJO_ENGAGEMENT_ID}"

        // Background-import polling in defectdojo_import.sh.
        DEFECTDOJO_POLL_INTERVAL_SECONDS = '5'
        DEFECTDOJO_POLL_TIMEOUT_SECONDS = '1800'

        REDMINE_URL = 'http://redmine:3000'
        REDMINE_PROJECT_ID = '1'
        REDMINE_TRACKER_ID = '1'
        REDMINE_STATUS_ID = '1'
        REDMINE_PRIORITY_ID = '2'

        // Safe default: don't reopen closed tickets.
        REDMINE_REOPEN_CLOSED = "${params.REOPEN_CLOSED_REDMINE_TICKETS}"
        REDMINE_REOPEN_STATUS_ID = "${params.REDMINE_REOPEN_STATUS_ID}"
        REDMINE_CLOSED_STATUS_IDS = "${params.REDMINE_CLOSED_STATUS_IDS}"

        PYTHONUNBUFFERED = '1'
    }

    stages {
        stage('Validate Configuration') {
            steps {
                sh '''
                    set -eu

                    for name in DEFECTDOJO_PRODUCT_ID DEFECTDOJO_ENGAGEMENT_ID; do
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
                                echo "ERROR: Closed status IDs must be comma-separated positive integers without spaces." >&2
                                exit 1
                            fi
                        done
                        IFS="$old_ifs"
                    fi

                    echo "Configuration validation passed."
                '''
            }
        }

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
                        notifyRedmineFailure('Checkout')
                    }
                }
            }
        }

        stage('Build and Unit Tests') {
            steps {
                sh '''
                    set -eu

                    if [ -f Makefile ] &&
                       grep -qE '^[[:space:]]*test:' Makefile; then
                        make test
                    elif [ -f pom.xml ]; then
                        mvn -B test package
                    elif [ -f package.json ]; then
                        npm ci
                        npm test
                    else
                        echo "No supported build detected."
                        echo "Add the application's build and test commands."
                        exit 2
                    fi
                '''
            }

            post {
                failure {
                    script {
                        notifyRedmineFailure('Build and Unit Tests')
                    }
                }
            }
        }

        stage('SonarQube SAST') {
            steps {
                catchError(
                    buildResult: 'UNSTABLE',
                    stageResult: 'FAILURE'
                ) {
                    withCredentials([
                        string(
                            credentialsId: 'sonarqube-token',
                            variable: 'SONAR_TOKEN'
                        )
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
            }

            post {
                failure {
                    script {
                        notifyRedmineFailure(
                            'SonarQube SAST',
                            'Quality gate failed or scanner error.'
                        )
                    }
                }
            }
        }

        stage('Trivy SCA') {
            steps {
                withCredentials([
                    string(
                        credentialsId: 'defectdojo-api-token',
                        variable: 'DEFECTDOJO_API_TOKEN'
                    )
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

                        /opt/devsecops/scripts/defectdojo_import.sh
                    '''
                }
            }

            post {
                always {
                    archiveArtifacts(
                        artifacts: 'artifacts/trivy/**',
                        allowEmptyArchive: true
                    )
                }

                failure {
                    script {
                        notifyRedmineFailure('Trivy SCA')
                    }
                }
            }
        }

        stage('Joern CPG Analysis') {
            steps {
                withCredentials([
                    string(
                        credentialsId: 'defectdojo-api-token',
                        variable: 'DEFECTDOJO_API_TOKEN'
                    )
                ]) {
                    sh '''
                        set -eu

                        mkdir -p artifacts/joern
                        command -v joern-parse >/dev/null

                        find . -type d \\( \
                            -name node_modules -o \
                            -name .git -o \
                            -name target -o \
                            -name build -o \
                            -name dist -o \
                            -name artifacts \
                        \\) -prune -o -type f -print \
                            > artifacts/joern/source-files.txt

                        run_parser() {
                            language="$1"
                            pattern="$2"
                            output="artifacts/joern/${language}-cpg.bin"
                            filelist="artifacts/joern/${language}-files.txt"

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

                            if find "$input_dir" -type f -print -quit | grep -q .; then
                                joern-parse \
                                    --language "$language" \
                                    --output "$output" \
                                    "$input_dir"
                                test -s "$output"
                            fi
                        }

                        run_parser javascript '\\.(js|jsx|mjs|cjs)$'
                        run_parser python '\\.py$'
                        run_parser java '\\.java$'
                        run_parser kotlin '\\.kt$'
                        run_parser golang '\\.go$'
                        run_parser csharp '\\.cs$'
                        run_parser php '\\.php$'
                        run_parser rubysrc '\\.rb$'
                        run_parser c '\\.c$'
                        run_parser newc '\\.(cc|cpp|cxx|h|hpp|hh|hxx)$'
                        run_parser rust '\\.rs$'
                        run_parser swift '\\.swift$'
                        run_parser abap '\\.abap$'

                        export DEFECTDOJO_TEST_TITLE="Joern CPG Analysis"

                        # This script must create a supported findings report
                        # and set DEFECTDOJO_SCAN_FILE and DEFECTDOJO_SCAN_TYPE
                        # before calling defectdojo_import.sh.
                        /opt/devsecops/scripts/joern_import.sh
                    '''
                }
            }

            post {
                always {
                    archiveArtifacts(
                        artifacts: 'artifacts/joern/**',
                        allowEmptyArchive: true
                    )
                }

                failure {
                    script {
                        notifyRedmineFailure('Joern CPG Analysis')
                    }
                }
            }
        }

        stage('Qualys Export') {
            when {
                expression { params.RUN_QUALYS }
            }

            steps {
                withCredentials([
                    usernamePassword(
                        credentialsId: 'qualys-credentials',
                        usernameVariable: 'QUALYS_USERNAME',
                        passwordVariable: 'QUALYS_PASSWORD'
                    ),
                    string(
                        credentialsId: 'defectdojo-api-token',
                        variable: 'DEFECTDOJO_API_TOKEN'
                    )
                ]) {
                    sh '''
                        set -eu

                        mkdir -p artifacts/qualys
                        export QUALYS_REPORT_ID="${QUALYS_REPORT_ID:-}"

                        /opt/devsecops/scripts/qualys_export.sh

                        export DEFECTDOJO_SCAN_FILE="artifacts/qualys/qualys-report.xml"
                        export DEFECTDOJO_SCAN_TYPE="Qualys Scan"
                        export DEFECTDOJO_TEST_TITLE="Qualys Vulnerability Scan"

                        /opt/devsecops/scripts/defectdojo_import.sh
                    '''
                }
            }

            post {
                always {
                    archiveArtifacts(
                        artifacts: 'artifacts/qualys/**',
                        allowEmptyArchive: true
                    )
                }

                failure {
                    script {
                        notifyRedmineFailure('Qualys Export')
                    }
                }
            }
        }

        stage('DefectDojo Import - SonarQube') {
            steps {
                withCredentials([
                    string(
                        credentialsId: 'defectdojo-api-token',
                        variable: 'DEFECTDOJO_API_TOKEN'
                    ),
                    string(
                        credentialsId: 'sonarqube-token',
                        variable: 'SONAR_TOKEN'
                    )
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

                            echo "$response" |
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
                                total: ($issues | length),
                                p: 1,
                                ps: ($issues | length)
                            }' > artifacts/sonar/sonar-report.json

                        test -s artifacts/sonar/sonar-report.json

                        export DEFECTDOJO_SCAN_FILE="artifacts/sonar/sonar-report.json"
                        export DEFECTDOJO_SCAN_TYPE="SonarQube Scan"
                        export DEFECTDOJO_TEST_TITLE="SonarQube SAST"

                        /opt/devsecops/scripts/defectdojo_import.sh
                    '''
                }
            }

            post {
                always {
                    archiveArtifacts(
                        artifacts: 'artifacts/sonar/**',
                        allowEmptyArchive: true
                    )
                }

                failure {
                    script {
                        notifyRedmineFailure('DefectDojo Import - SonarQube')
                    }
                }
            }
        }

        stage('Redmine Sync') {
            when {
                expression { params.SYNC_REDMINE }
            }

            steps {
                withCredentials([
                    string(
                        credentialsId: 'defectdojo-api-token',
                        variable: 'DEFECTDOJO_API_TOKEN'
                    ),
                    string(
                        credentialsId: 'redmine-api-key',
                        variable: 'REDMINE_API_KEY'
                    )
                ]) {
                    sh '/opt/devsecops/scripts/redmine_sync.sh'
                }
            }

            post {
                failure {
                    script {
                        notifyRedmineFailure('Redmine Sync')
                    }
                }
            }
        }
    }

    post {
        success {
            echo "Pipeline completed successfully. Build: #${env.BUILD_NUMBER}"
        }

        unstable {
            echo "Pipeline completed with unstable status. Build: #${env.BUILD_NUMBER}"
        }

        failure {
            echo "Pipeline failed. Build: #${env.BUILD_NUMBER}"
        }

        always {
            archiveArtifacts(
                artifacts: 'artifacts/**',
                allowEmptyArchive: true
            )
        }
    }
}
