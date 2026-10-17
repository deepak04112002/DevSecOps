# SonarQube Infrastructure

SonarQube runs as a Docker Compose service (`sonarqube`) backed by a dedicated PostgreSQL instance (`sonar-db`).

## Service details

| Item | Value |
|---|---|
| Image | `sonarqube:lts-community` |
| Internal URL | `http://sonarqube:9000` |
| Host URL | `http://localhost:9000` |
| Data volume | `sonar_data` |

## First-time setup

1. Open http://localhost:9000
2. Log in with `admin` / `admin` and change the password immediately.
3. Go to **My Account → Security → Generate Token** and create a token of type **User Token**.
4. Add the token to Jenkins as a **Secret text** credential with ID `sonarqube-token`.

## Project properties template

`sonar-project.properties.template` is a starting-point configuration file.

Copy it to the root of the application source and rename it:

```bash
cp infra/sonar/sonar-project.properties.template /path/to/your/app/sonar-project.properties
```

Edit the file to match your project's language, source paths, and coverage report format.

The pipeline passes `sonar.projectKey` and `sonar.token` on the command line, so those values in the template are only used when running `sonar-scanner` manually.

## Running sonar-scanner manually

```bash
cd /path/to/your/app
sonar-scanner \
  -Dsonar.projectKey=external-app \
  -Dsonar.host.url=http://localhost:9000 \
  -Dsonar.token=<your-token>
```

## Integration test

```bash
export SONAR_TOKEN=<your-token>
bash tests/integration/test_sonarqube.sh
```

## Quality Gate

The pipeline uses `-Dsonar.qualitygate.wait=true`, which causes the scanner to poll until the Quality Gate result is available and fail the build if the gate is not passed.

To configure the gate: **SonarQube UI → Quality Gates → Create / edit gate → assign to project**.
