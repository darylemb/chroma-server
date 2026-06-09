#!/usr/bin/env python
"""
Example: index a git repo into a chroma-server collection.

Usage:
    ./venv/bin/python scripts/ingest.py --repo /path/to/repo --collection my-notes
    ./venv/bin/python scripts/ingest.py --repo https://github.com/darylemb/gitops-dmxyz --collection gitops
"""
import argparse
import hashlib
import os
import subprocess
import sys
import tempfile
import time
import urllib.request
import json

CHROMA_URL = os.environ.get("CHROMA_URL", "http://127.0.0.1:8000")
# Files to skip
SKIP_DIRS = {".git", "node_modules", "__pycache__", "venv", ".venv", "target",
             "dist", "build", ".next", ".terraform", "vendor"}
SKIP_EXTS = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".pdf", ".zip",
             ".tar", ".gz", ".tgz", ".mp4", ".mov", ".mp3", ".woff", ".woff2",
             ".ttf", ".eot", ".ico", ".bin", ".so", ".dylib", ".dll", ".pyc"}
MAX_FILE_BYTES = 200_000  # 200 KB
CHUNK_SIZE = 1500  # chars


def http(method, path, data=None):
    url = f"{CHROMA_URL}{path}"
    headers = {"Content-Type": "application/json"}
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, json.loads(resp.read() or "null")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "ignore")
    except Exception as e:
        return 0, str(e)


def chunk_text(text, size):
    return [text[i:i + size] for i in range(0, len(text), size)]


def maybe_clone(repo_arg):
    if repo_arg.startswith("http") or repo_arg.startswith("git@"):
        tmp = tempfile.mkdtemp(prefix="chroma-ingest-")
        print(f"cloning {repo_arg} into {tmp}…")
        subprocess.run(["git", "clone", "--depth=1", repo_arg, tmp],
                       check=True, capture_output=True)
        return tmp
    return os.path.abspath(repo_arg)


def walk_files(root):
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith(".")]
        for f in files:
            if f.startswith("."):
                continue
            ext = os.path.splitext(f)[1].lower()
            if ext in SKIP_EXTS:
                continue
            p = os.path.join(base, f)
            try:
                if os.path.getsize(p) > MAX_FILE_BYTES:
                    continue
            except OSError:
                continue
            yield p


def ingest(root, collection, base_dir):
    # Ensure collection exists
    status, body = http("GET", "/api/v1/collections")
    if status != 200:
        print(f"error: cannot reach {CHROMA_URL}: {body}", file=sys.stderr)
        sys.exit(1)
    if not any(c["name"] == collection for c in body):
        print(f"creating collection {collection!r}")
        status, body = http("POST", "/api/v1/collections", {"name": collection})
        if status not in (200, 201):
            print(f"error creating collection: {status} {body}", file=sys.stderr)
            sys.exit(1)

    files = list(walk_files(root))
    print(f"found {len(files)} files in {root}")
    total_chunks = 0
    t0 = time.time()
    for i, path in enumerate(files, 1):
        try:
            with open(path, "r", encoding="utf-8", errors="ignore") as f:
                content = f.read()
        except Exception as e:
            print(f"  skip {path}: {e}")
            continue
        if not content.strip():
            continue
        rel = os.path.relpath(path, base_dir)
        chunks = chunk_text(content, CHUNK_SIZE)
        ids = [hashlib.sha1(f"{rel}::{i}".encode()).hexdigest()[:16] for i in range(len(chunks))]
        metadatas = [{"path": rel, "chunk": i, "total": len(chunks)} for i in range(len(chunks))]
        status, body = http("POST", f"/api/v1/collections/{collection}/add", {
            "ids": ids,
            "documents": chunks,
            "metadatas": metadatas,
        })
        if status != 200:
            print(f"  ✗ {rel}: {status} {body}")
        else:
            total_chunks += len(chunks)
            if i % 25 == 0 or i == len(files):
                print(f"  [{i}/{len(files)}] {rel}  (chunks: {total_chunks}, {time.time()-t0:.1f}s)")

    print(f"\n✓ done. {total_chunks} chunks indexed in {time.time()-t0:.1f}s")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True, help="Local path or git URL")
    ap.add_argument("--collection", required=True)
    ap.add_argument("--url", default=CHROMA_URL, help="chroma-server base URL")
    args = ap.parse_args()
    global CHROMA_URL
    CHROMA_URL = args.url

    workdir = maybe_clone(args.repo)
    try:
        ingest(workdir, args.collection, workdir)
    finally:
        if args.repo != workdir:
            import shutil
            shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    main()
