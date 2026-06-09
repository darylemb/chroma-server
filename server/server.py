"""
ChromaDB HTTP server with Prometheus metrics.
Wraps chromadb.PersistentClient (embedded mode) in a FastAPI app.

See README.md for the why.
"""
import os
import time
import logging
from typing import Any

import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel
import chromadb
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST

# --- config ---
CHROMA_PATH = os.environ.get("CHROMA_PATH", "./data")
HTTP_HOST = os.environ.get("HTTP_HOST", "127.0.0.1")
HTTP_PORT = int(os.environ.get("HTTP_PORT", "8000"))

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("chroma-server")

# --- metrics ---
REQS = Counter("chroma_requests_total", "Total HTTP requests", ["method", "path", "status"])
LATENCY = Histogram("chroma_request_duration_seconds", "Request latency", ["method", "path"])
QUERIES = Counter("chroma_queries_total", "Vector queries served")
DOCS_ADDED = Counter("chroma_documents_added_total", "Documents added")

# --- client ---
log.info(f"opening PersistentClient at {CHROMA_PATH}")
client = chromadb.PersistentClient(path=CHROMA_PATH)
log.info("client ready")

app = FastAPI(title="chroma-server", version="1.0.0")


@app.middleware("http")
async def metrics_middleware(request, call_next):
    t0 = time.perf_counter()
    response = await call_next(request)
    dt = time.perf_counter() - t0
    # Use route pattern, not full path
    route = request.scope.get("route").path if request.scope.get("route") else request.url.path
    REQS.labels(request.method, route, response.status_code).inc()
    LATENCY.labels(request.method, route).observe(dt)
    return response


@app.get("/api/v1/heartbeat")
def heartbeat():
    return {"nanosecond heartbeat": time.time_ns()}


@app.get("/api/v1/collections")
def list_collections():
    cols = [{"name": c.name, "id": str(c.id), "metadata": c.metadata} for c in client.list_collections()]
    return cols


class CreateCollectionBody(BaseModel):
    name: str
    metadata: dict[str, Any] | None = None


@app.post("/api/v1/collections")
def create_collection(body: CreateCollectionBody):
    try:
        col = client.get_or_create_collection(body.name, metadata=body.metadata)
        return {"name": col.name, "id": str(col.id)}
    except Exception as e:
        raise HTTPException(400, str(e))


@app.delete("/api/v1/collections/{name}")
def delete_collection(name: str):
    try:
        client.delete_collection(name)
        return {"ok": True}
    except Exception as e:
        raise HTTPException(404, str(e))


class AddBody(BaseModel):
    ids: list[str]
    documents: list[str] | None = None
    metadatas: list[dict[str, Any]] | None = None


class QueryBody(BaseModel):
    query_texts: list[str]
    n_results: int = 5
    where: dict[str, Any] | None = None


def _get_col(name: str):
    try:
        return client.get_collection(name)
    except Exception:
        raise HTTPException(404, f"collection {name!r} not found")


@app.post("/api/v1/collections/{name}/add")
def add(name: str, body: AddBody):
    col = _get_col(name)
    col.add(ids=body.ids, documents=body.documents, metadatas=body.metadatas)
    DOCS_ADDED.inc(len(body.ids))
    return {"ok": True, "added": len(body.ids)}


@app.post("/api/v1/collections/{name}/query")
def query(name: str, body: QueryBody):
    col = _get_col(name)
    QUERIES.inc()
    res = col.query(query_texts=body.query_texts, n_results=body.n_results, where=body.where)
    return res


@app.get("/metrics")
def metrics():
    return JSONResponse(content=generate_latest().decode("utf-8"), media_type=CONTENT_TYPE_LATEST)


@app.get("/")
def root():
    return {"service": "chroma-server", "version": "1.0.0", "collections": [c.name for c in client.list_collections()]}


if __name__ == "__main__":
    log.info(f"listening on {HTTP_HOST}:{HTTP_PORT}")
    uvicorn.run(app, host=HTTP_HOST, port=HTTP_PORT, log_level="info")
