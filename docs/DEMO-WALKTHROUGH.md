# Demo walkthrough & talking points

Run order for the demo. Aim: prove *only trusted, scanned, patched, signed images reach AKS* — using supported services, not ACR quarantine.

## 0. Setup (once, before the call)

```bash
# Create both registries (trusted + quarantine) + Defender plans (Containers + CSPM)
ACR=acrdemoregistry0429 QUARANTINE_ACR=acrquarantine0429 \
  RG=rg-acr-supplychain-demo bash infra/create-acr.sh

# One-time: create the AKV signing identity, then paste the printed signingKeyId
# into the pipeline (variable) or pass it at queue time.
KV=kvsigndemo0429 SIGNING_SP_OBJECT_ID=<ado-sp-object-id> bash infra/create-signing-key.sh

# Seed an image so the INGEST demo has something in quarantine to scan
az acr build --registry $ACR --image demo/sample-api:1 --file app/Dockerfile app
```

Additional one-time prereqs:
- **MicrosoftDefenderCLI** task: install from the Azure DevOps Marketplace (used by the BUILD pipeline's pre-push scan).
- **Defender for Cloud connector**: onboard your Azure DevOps org in Defender for Cloud (connector-based auth, preferred). Token-based auth via `DEFENDER_*` secrets is the alternative.
- **Cross-registry promotion roles** (INGEST pipeline): grant the ADO service-connection SP `AcrPull` on the quarantine ACR and `AcrPush` on the trusted ACR.

Give Defender ~15–30 min after a push to publish **registry** findings (INGEST). The BUILD pipeline's CLI scan is inline and returns in seconds.

## 1. The two pipelines (2 min)

Open both YAMLs side by side. They now show **two complementary gate models** for the same goal — *nothing untrusted reaches AKS*:

- **BUILD (our code)** — `docker build → Defender for Cloud CLI scan (break=true) → push on pass → sign`. True **shift-left**: the image is scanned **before** it is ever pushed, so a failing image never enters the registry.
- **INGEST (3rd-party image)** — `az acr import → Defender gate → Copa patch → re-gate → promote → sign`. The upstream image can't be rebuilt, so it lands in a **separate quarantine ACR** (no AKS access) and is only promoted to the trusted registry once it passes.

## 2a. BUILD — scan before push (the new shift-left message) (2 min)

- Open `pipelines/azure-pipelines-build.yml`. Stress: the `MicrosoftDefenderCLI@2`
  task runs the **same scanner Defender uses for ACR**, but **inline against the
  locally-built image**. `break: true` => breaking findings fail the task, the
  stage fails, and the **push step is never reached**. The trusted repo only ever
  receives a scanned, passing image.
- Build + scan + push share **one job** on purpose: the local image only exists on
  that agent until it passes and is pushed.

## 2b. INGEST — Defender as the registry gate (3 min)

- Open `scripts/defender-gate.sh`. Stress: **this reads Microsoft Defender for
  Containers**, via Azure Resource Graph (`microsoft.security/.../subassessments`),
  filtered to the exact image **digest**, in the **quarantine ACR**. It fails the
  build on findings above a configurable severity.
- "Defender is the security signal. Trivy is *not* the gate — it only shows up
  inside Copa because Copa needs a report in that format."
- Show a run where the older base **fails** the gate (Highs present).

## 3. Copacetic — fix without a rebuild (3 min)

- Open `scripts/copa-patch.sh`. Run the Patch stage. Copa writes a patched layer
  for the OS packages and pushes `:<tag>-patched`.
- The pipeline then **re-runs the Defender gate** on the patched image — show the
  CVE count drop. "Same image, no source rebuild, CVEs gone."
- Caveat to say out loud: **Copa = Linux OS packages only**; app/language CVEs are
  still fixed at build. (Also note **ACR Continuous Patching** does this on a
  schedule, registry-wide.)

## 4. Sign — turn 'passed' into proof (2 min)

- `scripts/sign-image.sh` signs the **patched** image with Notation (AKV or
  Artifact Signing). A signature now means "this image passed our controls".
- Only signed, patched images get promoted to the **golden** repo.

## 5. Enforce at the cluster — close the loop (3 min)

Signing means nothing unless AKS checks it. Show the enforcement half:

```bash
# Install Ratify + Azure Policy on AKS, trust policy scoped to the golden repo,
# policy effect = Deny.
# Then:
kubectl run good --image=$ACR.azurecr.io/golden/ingested:1                       # admitted (signed, from trusted ACR)
kubectl run bad  --image=acrquarantine0429.azurecr.io/ingested:1         # DENIED (unsigned, quarantine ACR)
# -> admission webhook "validation.gatekeeper.sh" denied the request
```

That denial is the money shot: an unsigned/ungoverned image **cannot run**.

## 6. Wrap (1 min)

- Quarantine intent → achieved with supported services, enforced at the cluster.
- Phased rollout: Defender gate at `Audit` severity first, Policy at `Audit`
  effect first, then tighten to `Deny`.
- Next step: stand this up on your tenant as a PoC; reuse this repo's IaC + YAML.

---

### Notes / gotchas

- **Defender latency:** first scan after push can take 15–30 min. Pre-bake images
  before the call; have a recording as fallback. The gate is now **fail-closed**
  (`failOnInconclusive: true`): if no scan surfaces within the timeout the gate
  **fails** rather than warn-and-pass, so a timeout can't masquerade as a pass.
  Set `failOnInconclusive: false` only if you deliberately want the old behaviour.
- **Signing is live when `signingKeyId` is set.** Run `infra/create-signing-key.sh`
  once, then paste the printed key id into the pipeline's `signingKeyId` variable
  (in the YAML, a variable group, or the pipeline UI). Blank `signingKeyId` still
  safely skips the Sign stage. The ADO service-connection SP needs **Key Vault
  Crypto User** + **Key Vault Certificate User** on the vault.
- **Service connection scope:** the ARM connection needs reader at subscription
  scope for the Resource Graph query to see sub-assessments, plus `AcrPush` on the
  trusted ACR. For the INGEST promotion it also needs `AcrPull` on the **quarantine
  ACR** and `AcrPush` on the **trusted ACR**.
- **Defender for Cloud CLI (BUILD pipeline):** needs **Defender CSPM** enabled and
  the **MicrosoftDefenderCLI** ADO task installed. Prefer the Azure DevOps connector
  (connector-based auth); token-based auth uses `DEFENDER_TENANT_ID/CLIENT_ID/CLIENT_SECRET`.
- **Copa + buildkit:** Microsoft-hosted agents have Docker/buildx; `copa-patch.sh`
  spins up a buildx builder.
- **`maxAllowedSeverity`:** demo default is `Medium` (fails on High/Critical).
  Drop to `Low` to make even the patched image's residual mediums fail, if you
  want to show a stricter gate.
