# Joern CPG Analysis

[Joern](https://joern.io) is an open-source code analysis platform that builds a Code Property Graph (CPG) from source code and lets you query it with a Scala-based DSL.

## Image

Built from `infra/security/joern/Dockerfile` using the upstream `ghcr.io/joernio/joern` image.

> Pin the image to a specific digest or tag for reproducible builds:
> ```dockerfile
> FROM ghcr.io/joernio/joern:v4.0.100
> ```

The query script is copied into the image at `/opt/joern/query.sc`.

## Running On-Demand

```bash
# Via Task
task joern

# Via Docker Compose directly
docker compose --profile analysis run --rm joern
```

The container:
1. Parses `/workspace/external-app` into a CPG at `/workspace/artifacts/cpg.bin`
2. Runs `/opt/joern/query.sc` and prints results to stdout

Output is written to `artifacts/` on the host via the bind mount.

## Query Script

`infra/security/joern/query.sc` contains the Joern queries run against the CPG.

Current queries (illustrative):
- Print total method count
- List all discovered method names

### Customising queries

Edit `infra/security/joern/query.sc` and rebuild the image:

```bash
docker compose build joern
```

Example — find all methods that call `exec`:
```scala
@main def exec(): Unit = {
  cpg.method.filter(_.callOut.name("exec").nonEmpty).name.l.foreach(println)
}
```

Refer to the [Joern documentation](https://docs.joern.io) for the full query API.

## Jenkins Integration

The `Joern CPG Analysis` pipeline stage runs `joern-parse` and `joern` directly on the Jenkins agent (not via Docker). The agent must have Joern installed and on `PATH`.

Artifacts produced:
- `artifacts/cpg.bin` — the Code Property Graph binary
- `artifacts/joern-output.txt` — query output
