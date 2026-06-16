# Demo walkthrough

Run order for the demo.

## 0. Setup (once)

```bash
# Create the ACR + Defender plans (Containers + CSPM)
ACR=acrdemoregistry0429 RG=rg-acr-supplychain-demo bash infra/create-acr.sh

# Create the AKV signing identity, then paste the printed signingKeyId
# into the pipeline (variable) or pass it at queue time.
KV=kvsigndemo0429 SIGNING_SP_OBJECT_ID=<ado-sp-object-id> bash infra/create-signing-key.sh
```

One-time prereqs:
- **Defender CSPM** enabled on the subscription.
- **Defender CLI authentication**: onboard your Azure DevOps org via a connector in Defender for Cloud (connector-based auth), or use token-based auth via `DEFENDER_*` pipeline secrets.

The Defender CLI scan runs inline on the agent and returns in seconds.

## 1. The two pipelines

Both pipelines use the same model: pull or build the image onto the agent, scan it inline with the Defender CLI, patch with Copa if needed, re-scan, and push only on pass.

- **BUILD** — `docker build → Defender CLI scan → Copa patch → re-scan gate → push on pass → sign`.
- **INGEST** — `docker pull → Defender CLI scan → Copa patch → re-scan gate → push on pass → sign`.

## 2. Defender CLI scan before push

- Open `pipelines/azure-pipelines-build.yml` and `pipelines/azure-pipelines-ingest.yml`. The Defender CLI scans the local image. If breaking findings are present, the scan gate fails and the push step is not reached.
- Build/pull, scan, and push share one job. The local image exists on the agent until it passes and is pushed.

## 3. Copacetic patching

- Open `scripts/copa-patch.sh`. Copa writes a patched layer for the OS packages.
- The pipeline re-runs the Defender CLI scan on the patched image.
- Copa patches Linux OS packages only; application/language CVEs are fixed at build. ACR Continuous Patching does this on a schedule, registry-wide.

## 4. Sign

- `scripts/sign-image.sh` signs the image with Notation (AKV or Artifact Signing). Only signed, passing images are promoted to the trusted repo.

## 5. Enforce at the cluster

```bash
# Install Ratify + Azure Policy on AKS, trust policy scoped to the trusted repo,
# policy effect = Deny. Then:
kubectl run good --image=$ACR.azurecr.io/golden/ingested:1   # admitted (signed)
kubectl run bad  --image=docker.io/library/nginx:1.25.3      # denied (unsigned)
```

## 6. Rollout

- Defender gate at `Audit` severity first, Policy at `Audit` effect first, then tighten to `Deny`.

---

### Notes

- **Signing** is enabled when `signingKeyId` is set. Run `infra/create-signing-key.sh` once, then paste the printed key id into the pipeline's `signingKeyId` variable (YAML, variable group, or pipeline UI). A blank `signingKeyId` skips the Sign stage. The ADO service-connection SP needs **Key Vault Crypto User** and **Key Vault Certificate User** on the vault.
- **Service connection scope**: the ARM connection needs `AcrPush` on the trusted ACR.
- **Defender CLI** needs **Defender CSPM** enabled. Auth is via the Azure DevOps connector (connector-based) or token-based auth using `DEFENDER_TENANT_ID/CLIENT_ID/CLIENT_SECRET`.
- **Copa + buildkit**: Microsoft-hosted agents have Docker/buildx; `copa-patch.sh` spins up a buildx builder.
- **`maxAllowedSeverity`**: default is `Medium` (fails on High/Critical). Set to `Low` to fail on residual mediums.
