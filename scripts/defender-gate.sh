#!/usr/bin/env bash
#
# defender-gate.sh — Gate a pipeline on Microsoft Defender for Containers findings.
#
# This is the deliberate "Defender, NOT Trivy" control. After an image is pushed
# to ACR, Microsoft Defender for Containers (Microsoft Defender Vulnerability
# Management / MDVM) scans it agentlessly. This script reads those findings back
# via Azure Resource Graph and FAILS the build if the image has vulnerabilities
# at or above a threshold severity.
#
# Usage:
#   defender-gate.sh <acrName> <repository> <tag> [maxSeverity] [timeoutMinutes] [failOnInconclusive]
#
#   maxSeverity        Highest severity that is ALLOWED to pass (default: Medium).
#                      Anything strictly above it fails the gate. One of:
#                      Low | Medium | High | Critical
#   timeoutMinutes     How long to wait for Defender to publish a scan (default: 20).
#   failOnInconclusive Fail the gate (fail-closed) if no scan surfaces within the
#                      timeout (default: true). Set to "false" to fall back to the
#                      warn-and-pass behaviour. NOTE: Defender for Containers
#                      agentless registry scanning has real latency (often hours
#                      for a first scan), so a freshly pushed image frequently
#                      will NOT surface inside a short pipeline window. Use
#                      "false" for demo/CI runs that must complete; keep "true"
#                      in production where images are pre-baked/pre-scanned.
#
# Requires: az CLI, the resource-graph extension (auto-installed), jq.
set -euo pipefail

ACR_NAME="${1:?acrName required}"
REPOSITORY="${2:?repository required}"
TAG="${3:?tag required}"
MAX_SEVERITY="${4:-Medium}"
TIMEOUT_MIN="${5:-20}"
FAIL_ON_INCONCLUSIVE="${6:-true}"

# Defender for Cloud assessment: "Container registry images should have
# vulnerabilities resolved (powered by Microsoft Defender Vulnerability Management)"
ASSESSMENT_KEY="c0b7cfc6-3172-465a-b378-53c7ff2cc0d5"

declare -A RANK=( [Low]=1 [Medium]=2 [High]=3 [Critical]=4 )
THRESHOLD=${RANK[$MAX_SEVERITY]:?invalid maxSeverity}

echo "==> Ensuring resource-graph extension is present"
az extension show -n resource-graph >/dev/null 2>&1 || az extension add -n resource-graph -y >/dev/null

echo "==> Resolving image digest for ${REPOSITORY}:${TAG}"
TOP_DIGEST=$(az acr repository show -n "$ACR_NAME" --image "${REPOSITORY}:${TAG}" --query digest -o tsv)
# Multi-arch tags are an OCI image index; Microsoft Defender for Containers keys its
# findings on the per-PLATFORM child manifest, NOT the index digest. Resolve the
# linux/amd64 child when the tag is an index; single-arch tags (e.g. Copa-patched
# images) have no child list and resolve to themselves.
CHILD_DIGEST=$(az acr manifest show "${ACR_NAME}.azurecr.io/${REPOSITORY}@${TOP_DIGEST}" -o json 2>/dev/null \
  | jq -r 'if (.manifests != null) then ([.manifests[] | select(.platform.os=="linux" and .platform.architecture=="amd64") | .digest] | first // "") else "" end' 2>/dev/null || true)
DIGEST="${CHILD_DIGEST:-$TOP_DIGEST}"
echo "    tag (index) digest:           ${TOP_DIGEST}"
echo "    scanned digest (linux/amd64): ${DIGEST}"

# Resource Graph query: pull MDVM sub-assessments for THIS registry and image digest.
read -r -d '' QUERY <<EOF || true
securityresources
| where type == "microsoft.security/assessments/subassessments"
| where tostring(properties.additionalData.assessedResourceType) == "AzureContainerRegistryVulnerability"  // MDVM container findings; the legacy assessment GUID matches ZERO subassessments
| extend ad = properties.additionalData
| extend digest = tostring(ad.artifactDetails.digest),
         repo   = tostring(ad.artifactDetails.repositoryName),
         registry = tostring(ad.artifactDetails.registryHost),
         sev    = tostring(properties.status.severity),
         cve    = tostring(properties.id),
         ['title'] = tostring(properties.displayName)   // 'title' is a reserved word in the ARG KQL parser; bracket-quote it or the whole query fails with ParserFailure/BadRequest
| where registry =~ "${ACR_NAME}.azurecr.io"
| where digest == "${DIGEST}"
| project sev, ['title'], cve, repo, digest
EOF

echo "==> Waiting for Microsoft Defender for Containers scan results (timeout ${TIMEOUT_MIN}m)"
deadline=$(( $(date +%s) + TIMEOUT_MIN * 60 ))
results="[]"
while :; do
  # IMPORTANT: this query/parse must NEVER be fatal — a transient graph error or
  # an empty result must let the loop keep polling until the deadline, not kill
  # the whole gate via set -e/pipefail. Capture errors and treat as "not ready".
  err_file="$(mktemp)"
  if raw=$(az graph query -q "$QUERY" --first 1000 -o json 2>"$err_file"); then
    results=$(printf '%s' "$raw" | jq -c '.data // []' 2>/dev/null || echo '[]')
  else
    echo "    graph query returned non-zero (treating as not-ready):"
    sed 's/^/      /' "$err_file" | head -5
    results="[]"
  fi
  rm -f "$err_file"

  count=$(printf '%s' "$results" | jq 'length' 2>/dev/null || echo 0)
  if [[ "$count" -gt 0 ]]; then
    echo "    Defender returned ${count} finding(s)."
    break
  fi
  if [[ $(date +%s) -ge $deadline ]]; then
    echo "    No Defender findings surfaced within the timeout."
    echo "    (Either the image is clean, or the agentless scan has not completed yet.)"
    if [[ "$FAIL_ON_INCONCLUSIVE" == "true" ]]; then
      echo "##vso[task.logissue type=error]Defender scan INCONCLUSIVE within ${TIMEOUT_MIN}m for ${REPOSITORY}:${TAG} — failing closed."
      echo "GATE FAILED (fail-closed) — no scan result to trust. Pre-bake the image or raise the timeout."
      echo "  (Set failOnInconclusive=false to treat an inconclusive scan as a pass instead.)"
      exit 1
    fi
    echo "##vso[task.logissue type=warning]Defender scan inconclusive within ${TIMEOUT_MIN}m for ${REPOSITORY}:${TAG} (warn-and-pass mode)"
    echo "GATE PASSED (warn-and-pass) — Defender has not surfaced a scan yet; not blocking the pipeline."
    exit 0
  fi
  echo "    not ready yet; re-checking in 60s..."
  sleep 60
done

echo "==> Findings by severity:"
echo "$results" | jq -r 'group_by(.sev) | map({severity: .[0].sev, count: length}) | .[] | "    \(.severity): \(.count)"'

# Count findings strictly above the allowed threshold
blocking=$(echo "$results" | jq --argjson th "$THRESHOLD" '
  [ .[] | .sev as $s
    | { Low:1, Medium:2, High:3, Critical:4 }[$s]
    | select(. != null and . > $th) ] | length')

echo ""
echo "==> Gate: max allowed severity = ${MAX_SEVERITY}; blocking findings above it = ${blocking}"
if [[ "$blocking" -gt 0 ]]; then
  echo "    Top blocking CVEs:"
  echo "$results" | jq -r --argjson th "$THRESHOLD" '
    .[] | select(({Low:1,Medium:2,High:3,Critical:4}[.sev] // 0) > $th)
    | "      [\(.sev)] \(.title)"' | sort -u | head -15
  echo "##vso[task.logissue type=error]Defender for Containers found ${blocking} finding(s) above ${MAX_SEVERITY} in ${REPOSITORY}:${TAG}"
  echo "GATE FAILED — remediate (see Copacetic stage) or rebuild on a patched base."
  exit 1
fi

echo "GATE PASSED — no findings above ${MAX_SEVERITY}."
