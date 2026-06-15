FROM python:3.11-slim

WORKDIR /app

# chromadb requires sqlite >= 3.35. python:3.11-slim ships with 3.37+, so
# we don't need to rebuild python. We also don't need build-essential at
# runtime in this wrapper.

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
