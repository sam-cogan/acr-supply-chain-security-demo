#!/usr/bin/env bash
#
# create-acr.sh — Set up the demo registry and governance features.
#
# Creates a Premium ACR and enables the Defender for Containers and Defender
# CSPM plans plus ACR Continuous Patching.
set -euo pipefail

SUBSCRIPTION="${SUBSCRIPTION:-00000000-0000-0000-0000-000000000000}"
RG="${RG:-rg-acr-supplychain-demo}"
LOCATION="${LOCATION:-swedencentral}"
ACR="${ACR:?set ACR to a globally-unique name, e.g. acrdemoregistry0429}"

az account set --subscription "$SUBSCRIPTION"

echo "==> Resource group"
az group create -n "$RG" -l "$LOCATION" -o none

echo "==> Premium ACR"
az acr create -n "$ACR" -g "$RG" --sku Premium -l "$LOCATION" -o none

echo "==> Enable Microsoft Defender for Containers"
az security pricing create -n Containers --tier Standard -o none

echo "==> Enable Defender CSPM"
az security pricing create -n CloudPosture --tier Standard -o none

# Defender CLI authentication for the pipelines: onboard an Azure DevOps connector
# in Defender for Cloud (connector-based auth), or use token-based auth via
# DEFENDER_* pipeline secrets.

echo "==> Enable ACR Continuous Patching (Trivy + Copa, scheduled) [Preview]"
az extension add -n acrcssc -y >/dev/null 2>&1 || true
cat > /tmp/continuous-patch-filter.json <<'JSON'
{ "version": "v1", "tag-convention": "floating", "repositories": [ { "repository": "*", "tags": ["*"], "enabled": true } ] }
JSON
az acr supply-chain workflow create \
  -r "$ACR" -g "$RG" -t continuouspatchv1 \
  --schedule "7d" --config /tmp/continuous-patch-filter.json -o none 2>&1 || \
  echo "    (Continuous Patching is Preview; if this errors, enable it from the portal.)"

echo "==> Done. Login server:"
az acr show -n "$ACR" --query loginServer -o tsv
