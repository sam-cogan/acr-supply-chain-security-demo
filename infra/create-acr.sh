#!/usr/bin/env bash
#
# create-acr.sh — Reproducible setup of the demo registry + governance features.
#
# Creates a Premium ACR (Premium is required for continuous patching, geo-
# replication, private link, etc.), and turns on the Defender for Containers
# plan and ACR Continuous Patching.
set -euo pipefail

SUBSCRIPTION="${SUBSCRIPTION:-00000000-0000-0000-0000-000000000000}"
RG="${RG:-rg-acr-supplychain-demo}"
LOCATION="${LOCATION:-swedencentral}"
ACR="${ACR:?set ACR to a globally-unique name, e.g. acrdemoregistry0429}"
# Dedicated quarantine registry for the INGEST pipeline (3rd-party images land
# here first; nothing deploys from it). Defaults to <ACR>quar if not set.
QUARANTINE_ACR="${QUARANTINE_ACR:-acrquarantine0429}"

az account set --subscription "$SUBSCRIPTION"

echo "==> Resource group"
az group create -n "$RG" -l "$LOCATION" -o none

echo "==> Premium ACR (trusted/production registry)"
az acr create -n "$ACR" -g "$RG" --sku Premium -l "$LOCATION" -o none

echo "==> Quarantine ACR (untrusted landing zone for ingested 3rd-party images)"
# Standard is plenty for a short-lived quarantine. Give it NO AKS pull access.
az acr create -n "$QUARANTINE_ACR" -g "$RG" --sku Standard -l "$LOCATION" -o none

echo "==> Enable Microsoft Defender for Containers (subscription-level, paid plan)"
# Powers the registry-scanning gate used by the INGEST pipeline.
az security pricing create -n Containers --tier Standard -o none

echo "==> Enable Defender CSPM (subscription-level, paid plan)"
# Required for the Defender for Cloud CLI in-pipeline (pre-push) scan used by the
# BUILD pipeline. See: https://learn.microsoft.com/azure/defender-for-cloud/defender-cli-overview
az security pricing create -n CloudPosture --tier Standard -o none

# NOTE — cross-registry promotion (INGEST pipeline):
#   The ADO service-connection SP needs AcrPull on the quarantine ACR and
#   AcrPush on the trusted ACR so `az acr import` can promote between them:
#     az role assignment create --assignee <sp> --role AcrPull  --scope $(az acr show -n "$QUARANTINE_ACR" --query id -o tsv)
#     az role assignment create --assignee <sp> --role AcrPush  --scope $(az acr show -n "$ACR" --query id -o tsv)
# NOTE — in-pipeline scanning (BUILD pipeline):
#   Onboard an Azure DevOps connector in Defender for Cloud (connector-based auth,
#   preferred), or use token-based auth via DEFENDER_* pipeline secrets. Install
#   the MicrosoftDefenderCLI task from the Azure DevOps Marketplace.

echo "==> Enable ACR Continuous Patching (Trivy + Copa, scheduled) [Preview]"
az extension add -n acrcssc -y >/dev/null 2>&1 || true
# Example: weekly patch of everything tagged in the registry. Tune the filter.
cat > /tmp/continuous-patch-filter.json <<'JSON'
{ "version": "v1", "tag-convention": "floating", "repositories": [ { "repository": "*", "tags": ["*"], "enabled": true } ] }
JSON
az acr supply-chain workflow create \
  -r "$ACR" -g "$RG" -t continuouspatchv1 \
  --schedule "7d" --config /tmp/continuous-patch-filter.json -o none 2>&1 || \
  echo "    (Continuous Patching is Preview; if this errors, enable it from the portal.)"

echo "==> Done. Login server:"
az acr show -n "$ACR" --query loginServer -o tsv
