FROM jenkins/jenkins:lts-jdk21

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates \
       curl \
       git \
       jq \
       python3 \
       python3-requests \
       unzip \
    && rm -rf /var/lib/apt/lists/*

ARG SONAR_SCANNER_VERSION=6.2.0.4584

RUN curl -fsSL \
    "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_SCANNER_VERSION}-linux-x64.zip" \
    -o /tmp/sonar-scanner.zip \
    && unzip /tmp/sonar-scanner.zip -d /opt \
    && ln -s \
       "/opt/sonar-scanner-${SONAR_SCANNER_VERSION}-linux-x64/bin/sonar-scanner" \
       /usr/local/bin/sonar-scanner \
    && rm /tmp/sonar-scanner.zip

COPY casc/ /usr/share/jenkins/ref/casc/

USER jenkins