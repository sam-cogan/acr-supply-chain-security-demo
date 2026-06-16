#!/usr/bin/env bash
#
# copa-patch.sh — Patch OS-level CVEs in-place with Copacetic (no rebuild).
#
# Copa requires a vulnerability report from a scanner. Trivy is the canonical
# Copa input and is used HERE ONLY to feed Copa — the security *gate* in this
# demo is Microsoft Defender for Containers (see defender-gate.sh). Copa fixes
# Linux OS-package CVEs; app/language CVEs must still be fixed at build.
#
# Usage:
#   copa-patch.sh <acrLoginServer> <repository> <tag> [patchedTag]
#
# Result: pushes <repository>:<patchedTag> (default "<tag>-patched") to ACR.
#
# Requires: docker (with buildx/buildkit), trivy, copa, az (already logged in
# and `az acr login` done for the target registry).
set -euo pipefail

ACR_LOGIN="${1:?acrLoginServer required, e.g. acrdemoregistry0429.azurecr.io}"
REPOSITORY="${2:?repository required}"
TAG="${3:?tag required}"
PATCHED_TAG="${4:-${TAG}-patched}"

IMAGE="${ACR_LOGIN}/${REPOSITORY}:${TAG}"
PATCHED_IMAGE="${ACR_LOGIN}/${REPOSITORY}:${PATCHED_TAG}"

echo "==> Pulling ${IMAGE}"
docker pull "$IMAGE"

echo "==> Scanning with Trivy to produce a Copa input report (Trivy is Copa's feed, not the gate)"
trivy image --vuln-type os --ignore-unfixed --format json --output copa-report.json "$IMAGE"

echo "==> Ensuring a buildkit instance is available for Copa"
# Copa needs a buildkit endpoint. docker buildx provides one.
docker buildx create --use --name copa-builder 2>/dev/null || docker buildx use copa-builder

echo "==> Patching OS packages in-place with Copacetic"
copa patch -i "$IMAGE" -r copa-report.json -t "$PATCHED_TAG"
# copa produces a local image tagged <repo>:<patchedTag>; retag to the full ACR ref
docker tag "${REPOSITORY}:${PATCHED_TAG}" "$PATCHED_IMAGE" 2>/dev/null || true

echo "==> Pushing patched image ${PATCHED_IMAGE}"
docker push "$PATCHED_IMAGE"

echo "==> Done. Re-run the Defender gate against ${PATCHED_TAG} to prove the CVE delta."
echo "PATCHED_IMAGE=${PATCHED_IMAGE}"
