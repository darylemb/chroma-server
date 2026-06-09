FROM python:3.11-slim

WORKDIR /app

# System deps for chromadb's rust binding (kept for completeness even though
# we use PersistentClient and don't need it at runtime in this wrapper).
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY server.py .

ENV CHROMA_PATH=/data
ENV HTTP_HOST=0.0.0.0
ENV HTTP_PORT=8000

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/api/v1/heartbeat', timeout=2).read()"

CMD ["python", "server.py"]
