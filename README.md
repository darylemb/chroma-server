# chroma-server

A small HTTP API around [ChromaDB](https://github.com/chroma-core/chroma)'s
`PersistentClient` (embedded mode) with **Prometheus metrics** out of the box.

## Why this exists

The official `chroma run` server (Rust binding) does not work on every host
where `chromadb` itself works. On Oracle Linux 9 / aarch64 (Ampere) it
silently exits with code 0 and no output, leaving you with a working
`PersistentClient` and no HTTP surface.

This repo is a ~140-line FastAPI wrapper that exposes the same `/api/v1`
endpoints, runs in pure Python, and adds Prometheus metrics that the official
server does not expose.

## Features

- HTTP API compatible with the official Chroma client (`chromadb.HttpClient`)
- `/metrics` in Prometheus text format (counters + histograms for queries, latency, etc.)
- Persistent storage (file-backed, no separate DB process)
- Auto-loaded ONNX embedding model (`all-MiniLM-L6-v2`, 79 MB, downloaded on first run)
- Single-binary deployment, runs as a systemd service

## Endpoints

| Method | Path | Body |
|---|---|---|
| `GET`  | `/api/v1/heartbeat` | — |
| `GET`  | `/api/v1/collections` | — |
| `POST` | `/api/v1/collections` | `{"name": "..."}` |
| `DELETE` | `/api/v1/collections/{name}` | — |
| `POST` | `/api/v1/collections/{name}/add` | `{"ids": [...], "documents": [...], "metadatas": [...]}` |
| `POST` | `/api/v1/collections/{name}/query` | `{"query_texts": [...], "n_results": 5}` |
| `GET`  | `/metrics` | — |

## Quick start (local)

```bash
# 1. Create venv and install
python3.11 -m venv venv
./venv/bin/pip install -r server/requirements.txt

# 2. Run
CHROMA_PATH=./data ./venv/bin/python server/server.py
# → listening on http://127.0.0.1:8000
```

## Install as systemd service (Linux)

```bash
sudo ./scripts/install.sh
# Service: chroma.service
# Logs:    journalctl -u chroma -f
# Data:    /opt/chroma/data
# Bin:     /opt/chroma/venv
```

## Run in Docker

```bash
docker build -t chroma-server -f server/Dockerfile .
docker run -d --name chroma -p 8000:8000 -v chroma-data:/data chroma-server
```

## Configuration

Environment variables:

| Var | Default | Description |
|---|---|---|
| `CHROMA_PATH` | `./data` | Where the embedded DB lives |
| `HTTP_HOST`   | `127.0.0.1` | Bind address |
| `HTTP_PORT`   | `8000` | Bind port |

## Prometheus integration

`/metrics` exposes:

- `chroma_requests_total{method,path,status}` — request counter
- `chroma_request_duration_seconds{method,path}` — latency histogram
- `chroma_queries_total` — vector queries served
- `chroma_documents_added_total` — documents added

Standard `process_*` and `python_*` metrics are also exported by
`prometheus_client`.

Sample scrape config:

```yaml
scrape_configs:
  - job_name: chroma
    static_configs:
      - targets: ['127.0.0.1:8000']
```

## Why not just use the official `chroma run`?

See [`docs/why.md`](docs/why.md) for the full story. TL;DR: it works on most
platforms, but the Rust binding can silently fail (exit 0, no log, no port)
on some Linux/aarch64 combinations.

## License

MIT
