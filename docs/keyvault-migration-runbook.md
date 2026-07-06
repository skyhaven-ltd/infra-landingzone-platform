# Runbook: platform RG consolidation + Key Vault secret migration

One-time migration to:

- one resource group per environment (`rg-platform-{env}-uks-01`) holding the Terraform state storage account **and** platform Key Vault,
- **new** globally-unique resource names — `stplatform{env}uks02` and `kv-platform-{env}-uks-02` — because the schema-consistent `01` forms (`stplatformdevuks01`, `kv-platform-dev-uks-01`) are taken by third parties (verified 2026-07-06),
- GitHub environment **variables** for the `AZURE_*` OIDC identifiers (viewable, unlike secrets),
- the platform Key Vaults as source of truth for all workflow secrets.

Because the storage accounts and vaults get new names, **nothing is moved** — everything is created fresh by the bootstrap script and the only data step is copying state blobs. The old `rg-tfs-platform-*` / `rg-kv-platform-*` resources are deleted at the end.

Code changes are already in place across all repos, pinned to the placeholder SHA `0000000000000000000000000000000000000000 # v2.0.0`. Follow the steps in order.

## 1. Release pipeline-engineering-github-actions v2.0.0

Branch `major/platform-keyvault` contains: the new `keyvault-secrets` composite action, `reusable-terraform.yml` v2 (no `secrets:` block; `vars.AZURE_*` + Key Vault), the `terraform-backend-init` defaults (`rg-platform-<env>-uks-01` / `stplatform<env>uks02`), and doc updates.

1. Push the branch, open a PR, merge it. The `major/` prefix auto-tags **v2.0.0**.
2. Record the release SHA: `gh api repos/skyhaven-ltd/pipeline-engineering-github-actions/git/ref/tags/v2.0.0 --jq .object.sha` (if the tag object is annotated, dereference with `^{}` via `git ls-remote`).

This release is inert for consumers until they re-pin.

## 2. Swap the placeholder SHA in every repo

From `C:\Local Files\Repositories\Sky Haven` (Git Bash), with `V2_SHA` set to the step-1 SHA:

```bash
V2_SHA=<release-sha>
grep -rl "0000000000000000000000000000000000000000" \
  */.github/workflows/*.yml | while read -r f; do
  sed -i "s/0000000000000000000000000000000000000000/${V2_SHA}/g" "$f"
done
```

## 3. Run the bootstrap script

```bash
az login
gh auth login
bash infra-landingzone-platform/scripts/bootstrap-platform.sh
```

Single pass, runs to completion: creates `rg-platform-{prd,dev}-uks-01` + delete locks, `stplatform{prd,dev}uks02` (versioning + soft delete), `kv-platform-{prd,dev}-uks-02` (RBAC, purge protection), grants **you** `Key Vault Secrets Officer` on both vaults, grants the three SPNs `Storage Account Contributor` on both new SAs and `Key Vault Secrets User` on both new vaults, ensures SPNs/federated credentials, ensures GitHub environments, sets the four `AZURE_*` **environment variables** per repo/env, deletes the legacy `AZURE_*` environment secrets, and grants/consents Graph `Application.Read.All`.

Rerun to confirm idempotency: expect only "already exists, skipping" output.

## 4. Copy state blobs to the new storage accounts (no CI running)

Per environment (`prd`, `dev`), copy every repo's state container from the old account to the new one. Account-key auth is simplest for a one-off copy (you have Owner, so you can read keys):

```bash
ENV=prd  # then repeat with ENV=dev
SUB=cefc8742-e1dd-4b24-90a9-07e3d3c80d88
OLD=sttfsplatform${ENV}uks01
NEW=stplatform${ENV}uks02

OLD_KEY=$(az storage account keys list --account-name $OLD --subscription $SUB --query "[0].value" -o tsv)
NEW_KEY=$(az storage account keys list --account-name $NEW --subscription $SUB --query "[0].value" -o tsv)

for c in $(az storage container list --account-name $OLD --account-key "$OLD_KEY" --query "[].name" -o tsv); do
  echo "=== $c"
  az storage container create --name "$c" --account-name $NEW --account-key "$NEW_KEY" --output none
  az storage blob copy start-batch \
    --source-account-name $OLD --source-account-key "$OLD_KEY" --source-container "$c" \
    --destination-container "$c" --account-name $NEW --account-key "$NEW_KEY"
done

# Verify: every blob present and copy status succeeded
for c in $(az storage container list --account-name $NEW --account-key "$NEW_KEY" --query "[].name" -o tsv); do
  az storage blob list --container-name "$c" --account-name $NEW --account-key "$NEW_KEY" \
    --query "[].{name:name, status:properties.copy.status}" -o table
done
```

All copies must show `success` before continuing. State blobs are small; this is near-instant.

## 5. Populate the Key Vault secrets

Values come from your password manager / the original providers (GitHub secrets are write-only). For each vault (`kv-platform-prd-uks-02`, `kv-platform-dev-uks-02`):

```bash
az keyvault secret set --vault-name <vault> --name <name> --value '<value>'
```

| Secret name                          | Vaults    |
| ------------------------------------ | --------- |
| `cloudflare-api-token`               | prd + dev |
| `cloudflare-account-id`              | prd + dev |
| `infracost-api-key`                  | prd + dev |
| `porkbun-api-key`                    | prd       |
| `porkbun-secret-api-key`             | prd       |
| `braveart-yoco-secret-key`           | prd + dev |
| `certwatch-entra-client-secret`      | prd + dev |
| `certwatch-brevo-api-key`            | prd + dev |
| `cvengine-blog-notify-secret`        | prd + dev |
| `cvengine-brevo-api-key`             | prd + dev |
| `github-platform-gh-app-id`          | prd       |
| `github-platform-gh-app-private-key` | prd       |

For the multiline GH App PEM: `az keyvault secret set --vault-name kv-platform-prd-uks-02 --name github-platform-gh-app-private-key --file <key.pem>`.

Verify visibility (the original pain point): `az keyvault secret show --vault-name kv-platform-prd-uks-02 --name cloudflare-api-token --query value -o tsv`.

## 6. Merge repo PRs and verify

Order matters only for this repo (its PR validation is the end-to-end test of the whole new path):

1. **infra-landingzone-platform** — PR from `minor/reusable-templates`. `pr-validation.yml` exercises reusable-terraform v2: vars-based OIDC login, KV-sourced `TF_VAR_*`, new backend RG/SA, Checkov. A **no-change plan** also proves the copied state blob is intact. Merge.
2. Each consumer repo — one PR each (branch prefix `patch/**`): app-braveart-gallery, app-certwatch-web, app-cvengine-portfolio, app-powertoggle-vm, infra-engineering-template, infra-github-platform. After merging each, run `gh workflow run terraform.yml -f terraform_action=plan` (add `-f env=prd` where applicable) and expect a clean init against `stplatform{env}uks02` and a no-change plan. For repos with `swa.yml`, a dispatch run confirms the vars-based login and KV fetches.

## 7. Cleanup

Once every repo is green:

```bash
# Delete now-unused GitHub secrets (per repo; env-scoped where they were env-scoped)
# List what's actually present first: gh secret list --repo skyhaven-ltd/<repo> [--env <env>]
gh secret delete CLOUDFLARE_API_TOKEN --repo skyhaven-ltd/<repo> [--env <env>]
# ... repeat for: CLOUDFLARE_ACCOUNT_ID, PORKBUN_API_KEY, PORKBUN_SECRET_API_KEY,
#     YOCO_SECRET_KEY, ENTRA_CLIENT_SECRET, BREVO_API_KEY, BLOG_NOTIFY_SECRET,
#     GH_APP_ID, GH_APP_PRIVATE_KEY, TF_VARS_JSON, INFRACOST_API_KEY

# Delete the old resource groups (locks first). This deletes the old storage
# accounts and the old prd vault (kv-platform-prd-uks-01 stays recoverable in
# soft-delete for 90 days; its name is abandoned, not reused).
SUB=cefc8742-e1dd-4b24-90a9-07e3d3c80d88
for rg in rg-tfs-platform-prd-uks-01 rg-tfs-platform-dev-uks-01 rg-kv-platform-prd-uks-01; do
  az lock delete --name delete-lock --resource-group "$rg" --subscription $SUB
  az group delete --name "$rg" --subscription $SUB --yes
done
# rg-kv-platform-dev-uks-01 may not exist (the dev vault was never created); skip if absent.
```

Also update your local terraform init to the new backend (`rg-platform-prd-uks-01` / `stplatformprduks02`) per CLAUDE.md.

## Rollback

Until step 6 the old accounts/state are untouched — the old workflows keep working and you can abandon at any point. After consumer PRs merge, rolling back a repo is just reverting its PR (its state still exists in the old account until step 7). Only after step 7's deletion is the old path gone; the new accounts have versioning + soft delete as the safety net.
