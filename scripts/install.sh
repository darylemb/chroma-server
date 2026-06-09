#!/usr/bin/env bash
# Install chroma-server as a systemd service on Linux.
#
# Layout:
#   /opt/chroma/server/   ← server.py
#   /opt/chroma/venv/     ← Python venv
#   /opt/chroma/data/     ← PersistentClient storage
#
# Why /opt and not /home: on distros with SELinux in enforcing mode (RHEL,
# Oracle Linux, CentOS Stream), files in /home are labeled user_home_t and
# cannot be exec'd by systemd (init_t). /opt gets the usr_t label, which is
# exec-friendly by default.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="/opt/chroma"
RUN_USER="${SUDO_USER:-${USER:-opc}}"

if [[ $EUID -ne 0 ]]; then
  echo "must be run as root (use sudo)" >&2
  exit 1
fi

echo "→ creating $TARGET"
mkdir -p "$TARGET/server" "$TARGET/data"

echo "→ copying server"
cp "$REPO_DIR/server/server.py" "$TARGET/server/server.py"
cp "$REPO_DIR/server/requirements.txt" "$TARGET/server/requirements.txt"

echo "→ creating venv at $TARGET/venv"
# Use the system Python 3.11+ (needed for bundled sqlite >= 3.35).
PY_BIN="$(command -v python3.11 || command -v python3)"
"$PY_BIN" -m venv "$TARGET/venv"

echo "→ installing dependencies"
"$TARGET/venv/bin/pip" install --upgrade pip
"$TARGET/venv/bin/pip" install -r "$TARGET/server/requirements.txt"

echo "→ setting ownership to $RUN_USER"
chown -R "$RUN_USER:$RUN_USER" "$TARGET"

echo "→ installing systemd unit"
cp "$REPO_DIR/systemd/chroma.service" /etc/systemd/system/chroma.service
systemctl daemon-reload
systemctl enable chroma.service
systemctl restart chroma.service

echo "→ waiting for service to be ready"
for i in {1..30}; do
  if curl -fsS http://127.0.0.1:8000/api/v1/heartbeat >/dev/null 2>&1; then
    echo ""
    echo "✓ chroma-server is up at http://127.0.0.1:8000"
    echo "  metrics: http://127.0.0.1:8000/metrics"
    echo "  logs:    journalctl -u chroma -f"
    exit 0
  fi
  sleep 1
done

echo "✗ service did not become ready in 30s" >&2
journalctl -u chroma -n 50 --no-pager >&2
exit 1
