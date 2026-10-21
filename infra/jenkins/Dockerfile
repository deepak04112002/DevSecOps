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
       libxml2-utils \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && pip3 install --break-system-packages --no-cache-dir weasyprint

# Docker CLI — for building images inside the pipeline.
# Download the static binary directly (more reliable than the docker.io
# apt package, which may not be available on all Debian versions).
ARG DOCKER_VERSION=27.3.1
RUN curl -fsSL \
    "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz" \
    -o /tmp/docker.tgz \
    && tar -xzf /tmp/docker.tgz -C /tmp docker/docker \
    && mv /tmp/docker/docker /usr/local/bin/docker \
    && chmod +x /usr/local/bin/docker \
    && rm -rf /tmp/docker.tgz /tmp/docker

# Syft — SBOM (Software Bill of Materials) generation
ARG SYFT_VERSION=1.26.0
RUN curl -fsSL \
    "https://github.com/anchore/syft/releases/download/v${SYFT_VERSION}/syft_${SYFT_VERSION}_linux_amd64.tar.gz" \
    -o /tmp/syft.tar.gz \
    && tar -xzf /tmp/syft.tar.gz -C /usr/local/bin syft \
    && chmod +x /usr/local/bin/syft \
    && rm /tmp/syft.tar.gz

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

# Joern — code property graph analysis
RUN curl -fsSL https://github.com/joernio/joern/releases/latest/download/joern-install.sh \
    -o /tmp/joern-install.sh \
    && chmod +x /tmp/joern-install.sh \
    && /tmp/joern-install.sh --install-dir /opt/joern --no-interactive \
    && rm /tmp/joern-install.sh

# Gitleaks — git secret scanning
ARG GITLEAKS_VERSION=8.30.1
RUN curl -fsSL \
    "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
    -o /tmp/gitleaks.tar.gz \
    && tar -xzf /tmp/gitleaks.tar.gz -C /usr/local/bin gitleaks \
    && chmod +x /usr/local/bin/gitleaks \
    && rm /tmp/gitleaks.tar.gz

ENV PATH="/opt/joern/joern-cli:${PATH}"

COPY casc/ /usr/share/jenkins/ref/casc/

USER jenkins
