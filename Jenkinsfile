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

                : "${REDMINE_PROJECT_ID:?REDMINE_PROJECT_ID is required}"
                : "${REDMINE_TRACKER_ID:?REDMINE_TRACKER_ID is required}"
                : "${REDMINE_STATUS_ID:?REDMINE_STATUS_ID is required}"
                : "${REDMINE_PRIORITY_ID:?REDMINE_PRIORITY_ID is required}"

                jq -n \
                    --argjson project_id "$REDMINE_PROJECT_ID" \
                    --argjson tracker_id "$REDMINE_TRACKER_ID" \
                    --argjson status_id "$REDMINE_STATUS_ID" \
                    --argjson priority_id "$REDMINE_PRIORITY_ID" \
                    --arg stage "${REDMINE_FAILURE_STAGE:-Unknown}" \
                    --arg details "${REDMINE_FAILURE_DETAILS:-}" \
                    --arg job "$JOB_NAME" \
                    --arg build "$BUILD_NUMBER" \
                    --arg url "$BUILD_URL" \
                    '{
                        issue: {
                            project_id: $project_id,
                            tracker_id: $tracker_id,
                            status_id: $status_id,
                            priority_id: $priority_id,
                            subject: ("[PIPELINE FAILURE] " + $stage + " - " + $job + " #" + $build),
                            description: (
                                "Stage: " + $stage + "\n" +
                                (if $details == "" then "" else $details + "\n" end) +
                                "Job: " + $job + "\n" +
                                "Build: #" + $build + "\n" +
                                "URL: " + $url
                            )
                        }
                    }' > "$WORKSPACE/redmine-issue.json"

                curl --silent --show-error --output /dev/null --max-time 10 \
                    --request POST \
                    --header "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
                    --header "Content-Type: application/json" \
                    --data @"$WORKSPACE/redmine-issue.json" \
                    "${REDMINE_URL}/issues.json" || true

                rm -f "$WORKSPACE/redmine-issue.json"
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
    }

    environment {
        SONAR_HOST_URL   = 'http://sonarqube:9000'
        DEFECTDOJO_URL   = 'http://defectdojo-nginx:8080'
        REDMINE_URL      = 'http://redmine:3000'

        REDMINE_PROJECT_ID  = '1'
        REDMINE_TRACKER_ID  = '1'
        REDMINE_STATUS_ID   = '1'
        REDMINE_PRIORITY_ID = '2'

        PYTHONUNBUFFERED = '1'
    }

    stages {
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
                        echo "Add your application's build and test commands."
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
                        command -v joern-parse

                        # Avoid scanning dependencies and generated files.
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

                            echo "Parsing language: $language"

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

                        echo "Joern parsing completed."

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

                        export QUALYS_REPORT_ID="${QUALYS_REPORT_ID:-}"

                        /opt/devsecops/scripts/qualys_export.sh

                        export DEFECTDOJO_SCAN_FILE="artifacts/qualys/qualys-report.xml"
                        export DEFECTDOJO_SCAN_TYPE="Qualys Scan"

                        /opt/devsecops/scripts/defectdojo_import.sh
                    '''
                }
            }

            post {
                failure {
                    script {
                        notifyRedmineFailure('Qualys Export')
                    }
                }
            }
        }

        stage('DefectDojo Import') {
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

                        # Paginate through all SonarQube issues.
                        page=1
                        total_pages=1
                        all_issues="[]"

                        while [ "$page" -le "$total_pages" ]; do
                            response="$(curl --silent --show-error --max-time 30 \
                                --header "Authorization: Bearer ${SONAR_TOKEN}" \
                                "${SONAR_HOST_URL}/api/issues/search?componentKeys=${SONAR_PROJECT_KEY}&resolved=false&ps=500&p=${page}&additionalFields=_all")"

                            total="$(echo "$response" | jq -r '.total // 0')"
                            total_pages=$(( (total + 499) / 500 ))

                            issues="$(echo "$response" | jq '.issues')"

                            all_issues="$(jq -n \
                                --argjson a "$all_issues" \
                                --argjson b "$issues" \
                                '$a + $b')"

                            page=$(( page + 1 ))
                        done

                        jq -n \
                            --argjson issues "$all_issues" \
                            '{
                                issues: $issues,
                                total: ($issues | length),
                                p: 1,
                                ps: ($issues | length)
                            }' > artifacts/sonar/sonar-report.json

                        export DEFECTDOJO_SCAN_FILE="artifacts/sonar/sonar-report.json"
                        export DEFECTDOJO_SCAN_TYPE="SonarQube Scan"

                        /opt/devsecops/scripts/defectdojo_import.sh
                    '''
                }
            }

            post {
                failure {
                    script {
                        notifyRedmineFailure('DefectDojo Import')
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
            sh 'echo "Pipeline completed successfully. Build: #${BUILD_NUMBER}"'
        }

        always {
            archiveArtifacts(
                artifacts: 'artifacts/**',
                allowEmptyArchive: true
            )
        }
    }
}
