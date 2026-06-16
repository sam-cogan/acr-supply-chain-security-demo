#!/usr/bin/env bash
#
# create-signing-key.sh — One-time setup of the Notation signing identity in
# Azure Key Vault, so the pipeline's Sign stage can run for real.
#
# Creates an AKV, a self-signed signing certificate suitable for Notation, grants
# the ADO pipeline service principal the rights it needs, and prints the
# `signingKeyId` you paste into the pipeline (set it as the `signingKeyId`
# variable in the YAML, or override it via a variable group / pipeline UI variable).
#
# For a production trust chain, replace the self-signed cert with one issued by
# your CA / Microsoft Artifact Signing — the wiring is identical.
set -euo pipefail

SUBSCRIPTION="${SUBSCRIPTION:-00000000-0000-0000-0000-000000000000}"
RG="${RG:-rg-acr-supplychain-demo}"
LOCATION="${LOCATION:-swedencentral}"
KV="${KV:?set KV to a globally-unique Key Vault name, e.g. kvsigndemo0429}"
CERT_NAME="${CERT_NAME:-demo-signing}"
CERT_SUBJECT="${CERT_SUBJECT:-CN=acr-supplychain-demo, O=Contoso, C=GB}"
# Service principal (appId/objectId) of the ADO ARM service connection that runs
# the Sign stage. It needs to read+sign with the key.
SIGNING_SP_OBJECT_ID="${SIGNING_SP_OBJECT_ID:-}"

az account set --subscription "$SUBSCRIPTION"

echo "==> Resource group"
az group create -n "$RG" -l "$LOCATION" -o none

echo "==> Key Vault (RBAC authorization model)"
az keyvault create -n "$KV" -g "$RG" -l "$LOCATION" \
  --enable-rbac-authorization true -o none

KV_ID=$(az keyvault show -n "$KV" --query id -o tsv)
ME=$(az ad signed-in-user show --query id -o tsv)

echo "==> Granting yourself 'Key Vault Certificates Officer' to create the cert"
az role assignment create --assignee-object-id "$ME" \
  --assignee-principal-type User \
  --role "Key Vault Certificates Officer" --scope "$KV_ID" -o none 2>/dev/null || true
echo "    (RBAC can take a minute to propagate; re-run if the next step 403s.)"
sleep 20

echo "==> Creating self-signed signing certificate '${CERT_NAME}'"
# x509 key usage digitalSignature; EKU codeSigning (1.3.6.1.5.5.7.3.3) for Notation.
cat > /tmp/notation-cert-policy.json <<JSON
{
  "issuerParameters": { "name": "Self" },
  "keyProperties": { "exportable": false, "keyType": "RSA", "keySize": 2048, "reuseKey": false },
  "secretProperties": { "contentType": "application/x-pem-file" },
  "x509CertificateProperties": {
    "subject": "${CERT_SUBJECT}",
    "keyUsage": [ "digitalSignature" ],
    "ekus": [ "1.3.6.1.5.5.7.3.3" ],
    "validityInMonths": 12
  }
}
JSON
az keyvault certificate create --vault-name "$KV" -n "$CERT_NAME" \
  -p @/tmp/notation-cert-policy.json -o none

echo "==> Resolving the signing key id (KID) for Notation"
KEY_ID=$(az keyvault certificate show --vault-name "$KV" -n "$CERT_NAME" --query kid -o tsv)

if [[ -n "$SIGNING_SP_OBJECT_ID" ]]; then
  echo "==> Granting the ADO pipeline SP signing rights"
  # Sign with the key + read the cert chain the plugin needs.
  az role assignment create --assignee-object-id "$SIGNING_SP_OBJECT_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "Key Vault Crypto User" --scope "$KV_ID" -o none 2>/dev/null || true
  az role assignment create --assignee-object-id "$SIGNING_SP_OBJECT_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "Key Vault Certificate User" --scope "$KV_ID" -o none 2>/dev/null || true
else
  echo "!!  SIGNING_SP_OBJECT_ID not set — skipping role grant for the pipeline SP."
  echo "    Grant the ADO service-connection SP 'Key Vault Crypto User' AND"
  echo "    'Key Vault Certificate User' on ${KV} before running the Sign stage."
fi

echo ""
echo "============================================================================"
echo " Signing is wired. Set this on the pipeline as the 'signingKeyId' variable:"
echo ""
echo "   signingKeyId: ${KEY_ID}"
echo ""
echo " Set it directly in the YAML (variables block), via a variable group, or as"
echo " a pipeline UI variable. Leave it blank to keep the Sign stage a no-op."
echo "============================================================================"
