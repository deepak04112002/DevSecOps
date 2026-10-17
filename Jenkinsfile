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
        PYTHONUNBUFFERED = '1'
    }

    stages {
        stage('Checkout') {
            steps {
                cleanWs()
                script {
                    if (params.GIT_REPOSITORY) {
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
                    withCredentials([string(credentialsId: 'redmine-api-key', variable: 'REDMINE_API_KEY')]) {
                        sh '''
                            curl --silent --output /dev/null --max-time 5 \
                                --request POST \
                                --header "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
                                --header "Content-Type: application/json" \
                                --data "{\"issue\":{\"project_id\":\"${DEFECTDOJO_PRODUCT_ID:-1}\",\"tracker_id\":1,\"priority_id\":5,\"subject\":\"[PIPELINE FAILURE] Checkout — ${JOB_NAME} #${BUILD_NUMBER}\",\"description\":\"Stage: Checkout\\nJob: ${JOB_NAME}\\nBuild: #${BUILD_NUMBER}\\nURL: ${BUILD_URL}\"}}" \
                                "${REDMINE_URL}/issues.json" || true
                        '''
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
                    withCredentials([string(credentialsId: 'redmine-api-key', variable: 'REDMINE_API_KEY')]) {
                        sh '''
                            curl --silent --output /dev/null --max-time 5 \
                                --request POST \
                                --header "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
                                --header "Content-Type: application/json" \
                                --data "{\"issue\":{\"project_id\":\"${DEFECTDOJO_PRODUCT_ID:-1}\",\"tracker_id\":1,\"priority_id\":5,\"subject\":\"[PIPELINE FAILURE] Build and Unit Tests — ${JOB_NAME} #${BUILD_NUMBER}\",\"description\":\"Stage: Build and Unit Tests\\nJob: ${JOB_NAME}\\nBuild: #${BUILD_NUMBER}\\nURL: ${BUILD_URL}\"}}" \
                                "${REDMINE_URL}/issues.json" || true
                        '''
                    }
                }
            }
        }

        stage('SonarQube SAST') {
            steps {
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
            post {
                failure {
                    withCredentials([
                        string(credentialsId: 'redmine-api-key', variable: 'REDMINE_API_KEY'),
                        string(credentialsId: 'defectdojo-api-token', variable: 'DEFECTDOJO_API_TOKEN')
                    ]) {
                        sh '''
                            curl --silent --output /dev/null --max-time 5 \
                                --request POST \
                                --header "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
                                --header "Content-Type: application/json" \
                                --data "{\"issue\":{\"project_id\":\"${DEFECTDOJO_PRODUCT_ID:-1}\",\"tracker_id\":1,\"priority_id\":5,\"subject\":\"[PIPELINE FAILURE] SonarQube SAST — ${JOB_NAME} #${BUILD_NUMBER}\",\"description\":\"Stage: SonarQube SAST\\nQuality gate failed or scanner error.\\nJob: ${JOB_NAME}\\nBuild: #${BUILD_NUMBER}\\nURL: ${BUILD_URL}\"}}" \
                                "${REDMINE_URL}/issues.json" || true

                            curl --silent --output /dev/null --max-time 5 \
                                --request POST \
                                --header "Authorization: Token ${DEFECTDOJO_API_TOKEN}" \
                                --header "Content-Type: application/json" \
                                --data "{\"engagement\":${DEFECTDOJO_ENGAGEMENT_ID:-1},\"notes\":\"SonarQube SAST stage failed — ${JOB_NAME} #${BUILD_NUMBER} — ${BUILD_URL}\"}" \
                                "${DEFECTDOJO_URL}/api/v2/notes/" || true
                        '''
                    }
                }
            }
        }


        stage('Joern CPG Analysis') {
            steps {
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

                        # Build a clean input directory containing only
                        # files matched for this language.
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
                '''
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
                    )
                ]) {
                    sh '''
                        set -eu
                        export QUALYS_REPORT_ID="${QUALYS_REPORT_ID:-}"
                        /opt/devsecops/scripts/qualys_export.sh
                    '''
                }
            }
            post {
                failure {
                    withCredentials([string(credentialsId: 'redmine-api-key', variable: 'REDMINE_API_KEY')]) {
                        sh '''
                            curl --silent --output /dev/null --max-time 5 \
                                --request POST \
                                --header "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
                                --header "Content-Type: application/json" \
                                --data "{\"issue\":{\"project_id\":\"${DEFECTDOJO_PRODUCT_ID:-1}\",\"tracker_id\":1,\"priority_id\":5,\"subject\":\"[PIPELINE FAILURE] Qualys Export — ${JOB_NAME} #${BUILD_NUMBER}\",\"description\":\"Stage: Qualys Export\\nJob: ${JOB_NAME}\\nBuild: #${BUILD_NUMBER}\\nURL: ${BUILD_URL}\"}}" \
                                "${REDMINE_URL}/issues.json" || true
                        '''
                    }
                }
            }
        }

        stage('DefectDojo Import') {
            steps {
                withCredentials([
                    string(credentialsId: 'defectdojo-api-token', variable: 'DEFECTDOJO_API_TOKEN'),
                    string(credentialsId: 'sonarqube-token', variable: 'SONAR_TOKEN')
                ]) {
                    sh '''
                        set -eu
                        mkdir -p artifacts/sonar
                        curl --silent --show-error --max-time 30 \
                            --header "Authorization: Bearer ${SONAR_TOKEN}" \
                            "${SONAR_HOST_URL}/api/issues/search?componentKeys=${SONAR_PROJECT_KEY}&resolved=false&ps=500" \
                            -o artifacts/sonar/sonar-report.json
                        export DEFECTDOJO_SCAN_FILE="artifacts/sonar/sonar-report.json"
                        export DEFECTDOJO_SCAN_TYPE="SonarQube Scan"
                        /opt/devsecops/scripts/defectdojo_import.sh
                    '''
                }
            }
            post {
                failure {
                    withCredentials([
                        string(credentialsId: 'redmine-api-key', variable: 'REDMINE_API_KEY'),
                        string(credentialsId: 'defectdojo-api-token', variable: 'DEFECTDOJO_API_TOKEN')
                    ]) {
                        sh '''
                            curl --silent --output /dev/null --max-time 5 \
                                --request POST \
                                --header "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
                                --header "Content-Type: application/json" \
                                --data "{\"issue\":{\"project_id\":\"${DEFECTDOJO_PRODUCT_ID:-1}\",\"tracker_id\":1,\"priority_id\":5,\"subject\":\"[PIPELINE FAILURE] DefectDojo Import — ${JOB_NAME} #${BUILD_NUMBER}\",\"description\":\"Stage: DefectDojo Import\\nJob: ${JOB_NAME}\\nBuild: #${BUILD_NUMBER}\\nURL: ${BUILD_URL}\"}}" \
                                "${REDMINE_URL}/issues.json" || true

                            curl --silent --output /dev/null --max-time 5 \
                                --request POST \
                                --header "Authorization: Token ${DEFECTDOJO_API_TOKEN}" \
                                --header "Content-Type: application/json" \
                                --data "{\"engagement\":${DEFECTDOJO_ENGAGEMENT_ID:-1},\"notes\":\"DefectDojo Import stage failed — ${JOB_NAME} #${BUILD_NUMBER} — ${BUILD_URL}\"}" \
                                "${DEFECTDOJO_URL}/api/v2/notes/" || true
                        '''
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
                    withCredentials([string(credentialsId: 'redmine-api-key', variable: 'REDMINE_API_KEY')]) {
                        sh '''
                            curl --silent --output /dev/null --max-time 5 \
                                --request POST \
                                --header "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
                                --header "Content-Type: application/json" \
                                --data "{\"issue\":{\"project_id\":\"${DEFECTDOJO_PRODUCT_ID:-1}\",\"tracker_id\":1,\"priority_id\":5,\"subject\":\"[PIPELINE FAILURE] Redmine Sync — ${JOB_NAME} #${BUILD_NUMBER}\",\"description\":\"Stage: Redmine Sync\\nJob: ${JOB_NAME}\\nBuild: #${BUILD_NUMBER}\\nURL: ${BUILD_URL}\"}}" \
                                "${REDMINE_URL}/issues.json" || true
                        '''
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
            archiveArtifacts artifacts: 'artifacts/**', allowEmptyArchive: true
        }
    }
}
