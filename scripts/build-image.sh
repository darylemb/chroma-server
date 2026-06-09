#!/usr/bin/env bash
# Build the chroma-server container image with buildah and import it into
# the k3s containerd image store so the cluster's pods can pull it with
# `imagePullPolicy: Never`.
#
# Why buildah: the host has no docker / podman / kaniko binary, but it does
# have buildah (from the k3s deps, or installed separately). It can build
# OCI images without a daemon.
#
# Why not just `podman build` / `docker build`: not installed.
#
# Why a tarball + ctr import: we deliberately chose NOT to push to any
# registry (the image stays local to the host and the k3s image store).
# This keeps the build offline-capable, no creds, no rate limits.
#
# Layout assumption: the script lives at scripts/build-image.sh inside the
# chroma-server repo, and the Dockerfile is at server/Dockerfile.
#
# Usage:
#   scripts/build-image.sh                # builds :1.0.0 by default
#   scripts/build-image.sh 1.2.3          # custom tag
#   scripts/build-image.sh --keep-storage # don't clean up buildah/storage
#                                          # and the intermediate tarball

set -euo pipefail

# ─── config ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCKERFILE="$REPO_DIR/server/Dockerfile"
BUILD_CONTEXT="$REPO_DIR/server"
IMAGE_NAME="chroma-server"
DEFAULT_TAG="1.0.0"
TAG="${1:-$DEFAULT_TAG}"
FULL_TAG="${IMAGE_NAME}:${TAG}"
OCI_TAR="/tmp/${IMAGE_NAME}-${TAG}.oci.tar"
K3S_NAMESPACE="k8s.io"
K3S_CTR="ctr"

# ─── arg parsing ───────────────────────────────────────────────────────────
KEEP_STORAGE=0
for arg in "$@"; do
  case "$arg" in
    --keep-storage) KEEP_STORAGE=1 ;;
    -h|--help)
      sed -n '3,28p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
  esac
done

# ─── preflight ─────────────────────────────────────────────────────────────
if [[ "$(id -u)" -ne 0 ]]; then
  # ctr needs to talk to /run/k3s/containerd/containerd.sock; only root can.
  echo "must be run as root (use sudo) so we can ctr import into k3s" >&2
  exit 1
fi

# buildah is normally on PATH for the user; ctr lives with k3s and is not
# visible under `sudo` from a user shell. Resolve ctr by absolute path first.
if ! command -v buildah >/dev/null 2>&1; then
  echo "missing required binary: buildah" >&2
  echo "  install with: sudo dnf install -y buildah" >&2
  exit 1
fi

if ! command -v "$K3S_CTR" >/dev/null 2>&1; then
  for p in /usr/local/bin/ctr /usr/bin/ctr; do
    [[ -x "$p" ]] && K3S_CTR="$p" && break
  done
fi
if ! [[ -x "$K3S_CTR" ]]; then
  echo "missing required binary: ctr (k3s ships it at /usr/local/bin/ctr)" >&2
  exit 1
fi

[[ -f "$DOCKERFILE" ]] || { echo "Dockerfile not found: $DOCKERFILE" >&2; exit 1; }

# ─── build with buildah ───────────────────────────────────────────────────
echo "▶ buildah build: $FULL_TAG from $DOCKERFILE"
buildah bud \
  --tag "$FULL_TAG" \
  --file "$DOCKERFILE" \
  "$BUILD_CONTEXT" 2>&1 | sed 's/^/  /'

# Resolve the image id from buildah's storage so we can target it for push.
# buildah stores images as `localhost/chroma-server:1.0.0` (not the bare
# `chroma-server:1.0.0`), so we match by the tag only.
IMAGE_ID="$(buildah images --format '{{.ID}} {{.Name}}:{{.Tag}}' \
  | awk -v t="$TAG" '$2 ~ (":"t"$") { print $1; exit }')"
if [[ -z "$IMAGE_ID" ]]; then
  echo "✗ buildah did not produce an image with tag $TAG" >&2
  exit 1
fi
echo "✓ built image id: $IMAGE_ID"

# ─── export to OCI tarball ────────────────────────────────────────────────
echo "▶ export to OCI tarball: $OCI_TAR"
rm -f "$OCI_TAR"
buildah push --format oci "localhost/${FULL_TAG}" "oci-archive:${OCI_TAR}:${IMAGE_NAME}:${TAG}" 2>&1 | sed 's/^/  /'
TAR_SIZE="$(du -h "$OCI_TAR" | cut -f1)"
echo "✓ exported: $OCI_TAR ($TAR_SIZE)"

# ─── import into k3s containerd ───────────────────────────────────────────
echo "▶ ctr import into namespace '$K3S_NAMESPACE'"
"$K3S_CTR" -n "$K3S_NAMESPACE" images import "$OCI_TAR" 2>&1 | sed 's/^/  /'

# Re-tag inside k8s.io namespace to a stable name (buildah defaults to
# `localhost/...`, ctr import also keeps the docker.io/library/ alias). We
# retag to the bare short name so the Deployment's image: chroma-server:1.0.0
# resolves cleanly with imagePullPolicy: Never.
"$K3S_CTR" -n "$K3S_NAMESPACE" images tag "localhost/${FULL_TAG}" "$FULL_TAG" 2>&1 | sed 's/^/  /' || true

echo
echo "✓ done. images available to k3s:"
"$K3S_CTR" -n "$K3S_NAMESPACE" images ls 2>&1 | grep -E "${IMAGE_NAME}(:|/)" | sed 's/^/  /'

# Drop the duplicate tagged entries that ctr import leaves behind. The image
# is also reachable under `localhost/chroma-server:T` and
# `docker.io/library/chroma-server:T`; we only need the bare short name for
# the Deployment's `image: chroma-server:T` to resolve with imagePullPolicy:
# Never.
echo "▶ prune duplicate tag entries"
for dup in "localhost/${FULL_TAG}" "docker.io/library/${FULL_TAG}"; do
  "$K3S_CTR" -n "$K3S_NAMESPACE" images rm "$dup" 2>&1 | sed 's/^/  /' || true
done

# ─── optional cleanup ─────────────────────────────────────────────────────
if [[ $KEEP_STORAGE -eq 0 ]]; then
  echo "▶ cleanup"
  buildah rmi -f "$FULL_TAG" 2>&1 | sed 's/^/  /' || true
  rm -f "$OCI_TAR"
  echo "✓ cleaned buildah storage and $OCI_TAR"
else
  echo "▶ --keep-storage set; left $OCI_TAR and buildah image in place"
fi

cat <<EOF

Next steps:
  - roll the deployment:    kubectl rollout restart deployment/chroma-server -n chroma
  - watch pods come up:     kubectl get pods -n chroma -w
  - hit the API:            curl http://127.0.0.1:8000/api/v1/heartbeat
EOF
