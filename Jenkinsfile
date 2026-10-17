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
            defaultValue: '',
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
    )

    environment {
        SONAR_HOST_URL   = 'http://sonarqube:9000'
        DEFECTDOJO_URL   = 'http://defectdojo-nginx:8080'
        REDMINE_URL      = 'http://redmine:3000'
        PYTHONUNBUFFERED = '1'
    }

    stages {
        stage('Checkout') {
            steps {
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
                            curl --silent --output /dev/null \
                                --request POST \
                                --header "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
                                --header "Content-Type: application/json" \
                                --data "{\"issue\":{\"project_id\":\"${DEFECTDOJO_PRODUCT_ID:-1}\",\"tracker_id\":1,\"priority_id\":5,\"subject\":\"[PIPELINE FAILURE] Checkout — ${JOB_NAME} #${BUILD_NUMBER}\",\"description\":\"Stage: Checkout\\nJob: ${JOB_NAME}\\nBuild: #${BUILD_NUMBER}\\nURL: ${BUILD_URL}\"}}" \
                                "${REDMINE_URL}/issues.json"
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
                            curl --silent --output /dev/null \
                                --request POST \
                                --header "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
                                --header "Content-Type: application/json" \
                                --data "{\"issue\":{\"project_id\":\"${DEFECTDOJO_PRODUCT_ID:-1}\",\"tracker_id\":1,\"priority_id\":5,\"subject\":\"[PIPELINE FAILURE] Build and Unit Tests — ${JOB_NAME} #${BUILD_NUMBER}\",\"description\":\"Stage: Build and Unit Tests\\nJob: ${JOB_NAME}\\nBuild: #${BUILD_NUMBER}\\nURL: ${BUILD_URL}\"}}" \
                                "${REDMINE_URL}/issues.json"
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
                            curl --silent --output /dev/null \
                                --request POST \
                                --header "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
                                --header "Content-Type: application/json" \
                                --data "{\"issue\":{\"project_id\":\"${DEFECTDOJO_PRODUCT_ID:-1}\",\"tracker_id\":1,\"priority_id\":5,\"subject\":\"[PIPELINE FAILURE] SonarQube SAST — ${JOB_NAME} #${BUILD_NUMBER}\",\"description\":\"Stage: SonarQube SAST\\nQuality gate failed or scanner error.\\nJob: ${JOB_NAME}\\nBuild: #${BUILD_NUMBER}\\nURL: ${BUILD_URL}\"}}" \
                                "${REDMINE_URL}/issues.json"

                            curl --silent --output /dev/null \
                                --request POST \
                                --header "Authorization: Token ${DEFECTDOJO_API_TOKEN}" \
                                --header "Content-Type: application/json" \
                                --data "{\"engagement\":${DEFECTDOJO_ENGAGEMENT_ID:-1},\"notes\":\"SonarQube SAST stage failed — ${JOB_NAME} #${BUILD_NUMBER} — ${BUILD_URL}\"}" \
                                "${DEFECTDOJO_URL}/api/v2/notes/"
                        '''
                    }
                }
            }
        }

        stage('Joern CPG Analysis') {
            steps {
                sh '''
                    set -eu

                    command -v joern-parse
                    command -v joern

                    joern-parse . \
                      --output artifacts/cpg.bin

                    joern --script /opt/joern/query.sc \
                      > artifacts/joern-output.txt
                '''
            }
            post {
                failure {
                    withCredentials([
                        string(credentialsId: 'redmine-api-key', variable: 'REDMINE_API_KEY'),
                        string(credentialsId: 'defectdojo-api-token', variable: 'DEFECTDOJO_API_TOKEN')
                    ]) {
                        sh '''
                            curl --silent --output /dev/null \
                                --request POST \
                                --header "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
                                --header "Content-Type: application/json" \
                                --data "{\"issue\":{\"project_id\":\"${DEFECTDOJO_PRODUCT_ID:-1}\",\"tracker_id\":1,\"priority_id\":5,\"subject\":\"[PIPELINE FAILURE] Joern CPG Analysis — ${JOB_NAME} #${BUILD_NUMBER}\",\"description\":\"Stage: Joern CPG Analysis\\nJob: ${JOB_NAME}\\nBuild: #${BUILD_NUMBER}\\nURL: ${BUILD_URL}\"}}" \
                                "${REDMINE_URL}/issues.json"

                            curl --silent --output /dev/null \
                                --request POST \
                                --header "Authorization: Token ${DEFECTDOJO_API_TOKEN}" \
                                --header "Content-Type: application/json" \
                                --data "{\"engagement\":${DEFECTDOJO_ENGAGEMENT_ID:-1},\"notes\":\"Joern CPG Analysis stage failed — ${JOB_NAME} #${BUILD_NUMBER} — ${BUILD_URL}\"}" \
                                "${DEFECTDOJO_URL}/api/v2/notes/"
                        '''
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
                    )
                ]) {
                    sh '''
                        set -eu
                        export QUALYS_REPORT_ID="${QUALYS_REPORT_ID:-}"
                        ./scripts/qualys_export.sh
                    '''
                }
            }
            post {
                failure {
                    withCredentials([string(credentialsId: 'redmine-api-key', variable: 'REDMINE_API_KEY')]) {
                        sh '''
                            curl --silent --output /dev/null \
                                --request POST \
                                --header "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
                                --header "Content-Type: application/json" \
                                --data "{\"issue\":{\"project_id\":\"${DEFECTDOJO_PRODUCT_ID:-1}\",\"tracker_id\":1,\"priority_id\":5,\"subject\":\"[PIPELINE FAILURE] Qualys Export — ${JOB_NAME} #${BUILD_NUMBER}\",\"description\":\"Stage: Qualys Export\\nJob: ${JOB_NAME}\\nBuild: #${BUILD_NUMBER}\\nURL: ${BUILD_URL}\"}}" \
                                "${REDMINE_URL}/issues.json"
                        '''
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
                    )
                ]) {
                    sh '''
                        set -eu
                        export DEFECTDOJO_SCAN_FILE="${DEFECTDOJO_SCAN_FILE:-artifacts/qualys/qualys-report.xml}"
                        ./scripts/defectdojo_import.sh
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
                            curl --silent --output /dev/null \
                                --request POST \
                                --header "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
                                --header "Content-Type: application/json" \
                                --data "{\"issue\":{\"project_id\":\"${DEFECTDOJO_PRODUCT_ID:-1}\",\"tracker_id\":1,\"priority_id\":5,\"subject\":\"[PIPELINE FAILURE] DefectDojo Import — ${JOB_NAME} #${BUILD_NUMBER}\",\"description\":\"Stage: DefectDojo Import\\nJob: ${JOB_NAME}\\nBuild: #${BUILD_NUMBER}\\nURL: ${BUILD_URL}\"}}" \
                                "${REDMINE_URL}/issues.json"

                            curl --silent --output /dev/null \
                                --request POST \
                                --header "Authorization: Token ${DEFECTDOJO_API_TOKEN}" \
                                --header "Content-Type: application/json" \
                                --data "{\"engagement\":${DEFECTDOJO_ENGAGEMENT_ID:-1},\"notes\":\"DefectDojo Import stage failed — ${JOB_NAME} #${BUILD_NUMBER} — ${BUILD_URL}\"}" \
                                "${DEFECTDOJO_URL}/api/v2/notes/"
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
                    sh './scripts/redmine_sync.sh'
                }
            }
            post {
                failure {
                    withCredentials([string(credentialsId: 'redmine-api-key', variable: 'REDMINE_API_KEY')]) {
                        sh '''
                            curl --silent --output /dev/null \
                                --request POST \
                                --header "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
                                --header "Content-Type: application/json" \
                                --data "{\"issue\":{\"project_id\":\"${DEFECTDOJO_PRODUCT_ID:-1}\",\"tracker_id\":1,\"priority_id\":5,\"subject\":\"[PIPELINE FAILURE] Redmine Sync — ${JOB_NAME} #${BUILD_NUMBER}\",\"description\":\"Stage: Redmine Sync\\nJob: ${JOB_NAME}\\nBuild: #${BUILD_NUMBER}\\nURL: ${BUILD_URL}\"}}" \
                                "${REDMINE_URL}/issues.json"
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
