#!/usr/bin/env bash
#
# sign-image.sh — Sign an image with Notation so AKS can enforce trust.
#
# Producer side of the trust chain. The image is signed at the END of the
# pipeline (only AFTER it has passed the Defender gate and been patched), so a
# signature becomes proof that "this image passed our controls". At deploy time
# AKS verifies the signature with Ratify + Azure Policy (Deny) — see docs.
#
# Two cert sources are supported:
#   akv             — certificate stored in Azure Key Vault (you manage lifecycle)
#   artifact-signing — Artifact Signing (formerly Trusted Signing): zero-touch,
#                      short-lived certs + RFC 3161 timestamping.
#
# Usage:
#   sign-image.sh <acrLoginServer> <repository> <tag> <certSource> <keyId>
#     certSource = akv | artifact-signing
#     keyId      = AKV key identifier (https://<vault>.vault.azure.net/keys/<name>/<ver>)
#                  or the Artifact Signing key reference.
#
# Requires: notation, notation azure-kv plugin, az (logged in), `az acr login`.
set -euo pipefail

ACR_LOGIN="${1:?acrLoginServer required}"
REPOSITORY="${2:?repository required}"
TAG="${3:?tag required}"
CERT_SOURCE="${4:-akv}"
KEY_ID="${5:?keyId / key reference required}"

IMAGE="${ACR_LOGIN}/${REPOSITORY}:${TAG}"

echo "==> Resolving digest (always sign by digest, never by mutable tag)"
DIGEST=$(az acr repository show -n "${ACR_LOGIN%%.*}" --image "${REPOSITORY}:${TAG}" --query digest -o tsv)
TARGET="${ACR_LOGIN}/${REPOSITORY}@${DIGEST}"
echo "    target: ${TARGET}"

echo "==> Registering AKV key with Notation"
notation key add --plugin azure-kv --id "$KEY_ID" "demo-signing-key" --default

echo "==> Signing ${TARGET} (source: ${CERT_SOURCE})"
if [[ "$CERT_SOURCE" == "artifact-signing" ]]; then
  # Artifact Signing issues short-lived certs; add RFC 3161 timestamping so the
  # signature remains verifiable after the cert expires.
  notation sign "$TARGET" \
    --plugin-config self_signed=false \
    --timestamp-url "http://timestamp.acs.microsoft.com" \
    --timestamp-root-cert "${TSA_ROOT_CERT:?set TSA_ROOT_CERT for artifact-signing}"
else
  notation sign "$TARGET"
fi

echo "==> Signatures now attached to ${TARGET}:"
notation ls "$TARGET"
echo "SIGNED=${TARGET}"
