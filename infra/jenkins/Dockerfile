FROM jenkins/jenkins:lts-jdk21

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates \
       curl \
       git \
       gnupg \
       jq \
       python3 \
       python3-pip \
       python3-requests \
       libpango-1.0-0 \
       libpangocairo-1.0-0 \
       libcairo2 \
       libgdk-pixbuf-xlib-2.0-0 \
       shared-mime-info \
       fonts-dejavu-core \
       unzip \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && pip3 install --break-system-packages --no-cache-dir weasyprint

# Trivy — SCA and filesystem vulnerability scanning
RUN curl -fsSL https://aquasecurity.github.io/trivy-repo/deb/public.key \
    | gpg --dearmor -o /usr/share/keyrings/trivy.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" \
    > /etc/apt/sources.list.d/trivy.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends trivy \
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

RUN curl -fsSL https://github.com/joernio/joern/releases/latest/download/joern-install.sh \
    -o /tmp/joern-install.sh \
    && chmod +x /tmp/joern-install.sh \
    && /tmp/joern-install.sh --install-dir /opt/joern --no-interactive \
    && rm /tmp/joern-install.sh

ENV PATH="/opt/joern/joern-cli:${PATH}"

COPY casc/ /usr/share/jenkins/ref/casc/

USER jenkins
