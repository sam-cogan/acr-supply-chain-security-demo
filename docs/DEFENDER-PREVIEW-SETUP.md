# Enabling the Defender for Cloud CLI gate

Both pipelines scan the local image (built or pulled) with the **Microsoft
Defender for Cloud CLI** before it is pushed to ACR. The CLI authenticates to
Defender for Cloud to upload findings and return a gating exit code. That
authentication is a one-time setup in the Azure portal.

Pick **one** of the two methods. Connector-based requires no secrets in the
pipeline.

---

## Prerequisites (both methods)

- Defender for Cloud onboarded on the subscription.
- **Defender CSPM** plan enabled.
- Permission to edit Defender **Environment settings** (Security Admin / Owner).

---

## Option A — Connector-based auth (no secrets)

Integrates Azure DevOps with Defender via a connector; the CLI authenticates
automatically with no `DEFENDER_*` variables required.

1. Azure portal → **Microsoft Defender for Cloud** → **Environment settings**.
2. **+ Add environment** → **Azure DevOps**.
3. Authorize and select the ADO organization (`<your-ado-org>`) and the
   **<your-project>** project.
4. Finish onboarding and wait for the connector to show **Connected**.
5. Re-run the pipeline — the `defender scan image` step authenticates via
   the connector automatically.

Docs: <https://learn.microsoft.com/azure/defender-for-cloud/quickstart-onboard-devops>

---

## Option B — Token-based auth (DevOps Ingestion, Preview)

Generates a scoped client ID / secret / tenant ID that you inject as **secret
pipeline variables**.

### 1. Generate the credentials (Azure portal — manual, one-time)

1. Sign in to the Azure portal → open **Microsoft Defender for Cloud**.
2. **Management → Environment settings → Integrations**.
3. **+ Add integration → DevOps Ingestion (Preview)**.
4. Enter an **application name** (e.g. `acr-build-gate`):
   - Choose the **tenant** to store the secret.
   - Set an **expiration date** and **enable** the token.
   - **Save**.
5. **Copy the Client ID, Client Secret, and Tenant ID immediately** —
   they cannot be retrieved again.

Docs: <https://learn.microsoft.com/azure/defender-for-cloud/defender-cli-authentication>

### 2. Add them as SECRET variables on the pipeline (ADO)

ADO → **Pipelines** → select the pipeline → **Edit** →
**Variables** (or a linked Variable Group), add — each marked **🔒 Keep this
value secret**:

| Variable name           | Value                       |
| ----------------------- | --------------------------- |
| `DEFENDER_TENANT_ID`    | Tenant ID from step 1       |
| `DEFENDER_CLIENT_ID`    | Client ID from step 1       |
| `DEFENDER_CLIENT_SECRET`| Client Secret from step 1   |

The YAML already wires these into the gate step's `env:` block — no YAML change
needed:

```yaml
env:
  DEFENDER_TENANT_ID: $(DEFENDER_TENANT_ID)
  DEFENDER_CLIENT_ID: $(DEFENDER_CLIENT_ID)
  DEFENDER_CLIENT_SECRET: $(DEFENDER_CLIENT_SECRET)
```

### 3. Re-run

Re-run the pipeline. The gate downloads the CLI from
`https://aka.ms/defender-cli_linux-x64`, scans the local image, and fails the
build (preventing the push) if breaking findings are found (`breakOnFindings`).

---

## Notes

- *DevOps Ingestion (Preview)* and CI/CD CLI scanning are in public preview;
  portal navigation and exact labels may change.
- Token-based secrets expire on the date you set — rotate them before expiry.
  Connector-based auth avoids this.
- The pipelines download the Defender CLI binary directly rather than using the
  `MicrosoftDefenderCLI` marketplace task.
