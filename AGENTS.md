# AGENTS.md

This file provides guidance to Codex CLI and other AI coding agents when working with code in this repository.

## Repository Purpose

Terraform root module for the Sky Haven Azure landing zone platform layer. Provisions management group hierarchy, hub networking (VNet, subnets, NSGs, route tables, network watcher), public DNS with Porkbun nameserver delegation, and per-subscription consumption budgets.

## Commands

### Local plan

Prerequisites: `az login` and the secret Terraform variables exported for local use. The platform Key Vault is the source of truth for secrets (requires `Key Vault Secrets Officer`/`User` on the vault):

```bash
export TF_VAR_cloudflare_api_token=$(az keyvault secret show --vault-name kv-platform-prd-uks-02 --name cloudflare-api-token --query value -o tsv)
export TF_VAR_cloudflare_account_id=$(az keyvault secret show --vault-name kv-platform-prd-uks-02 --name cloudflare-account-id --query value -o tsv)
export TF_VAR_porkbun_api_key=$(az keyvault secret show --vault-name kv-platform-prd-uks-02 --name porkbun-api-key --query value -o tsv)
export TF_VAR_porkbun_secret_api_key=$(az keyvault secret show --vault-name kv-platform-prd-uks-02 --name porkbun-secret-api-key --query value -o tsv)

terraform -chdir=infra init \
  -backend-config="resource_group_name=rg-platform-prd-uks-01" \
  -backend-config="storage_account_name=stplatformprduks02" \
  -backend-config="container_name=infra-landingzone-platform" \
  -backend-config="key=terraform.tfstate" \
  -backend-config="subscription_id=<platform-subscription-id>"

terraform -chdir=infra plan  -var-file="vars/globals.tfvars" -var-file="vars/prd.tfvars"
terraform -chdir=infra apply -var-file="vars/globals.tfvars" -var-file="vars/prd.tfvars"
```

### Bootstrap script (idempotent, not Terraform-managed)

- `scripts/bootstrap-platform.sh` - single script creating, per environment, the platform resource group (`rg-platform-{env}-uks-01`) with delete lock, tfstate storage account, platform Key Vault, OIDC service principals with federated credentials and role assignments, GitHub environments, and the `AZURE_*` GitHub environment variables. Safe to re-run.

## Pipeline Behaviour

Pipelines consume shared reusable workflows and composite actions from `skyhaven-ltd/pipeline-engineering-github-actions`, SHA-pinned to a released tag.

- **`lint.yml`** - MegaLinter via the shared `reusable-lint.yml` on every PR to `main`; tuned by `.github/validation/.mega-linter.yml`.
- **`pr-validation.yml`** - shared `reusable-terraform.yml`: Terraform hygiene, zizmor, then a real `prd` plan with Checkov deep analysis. Azure identity comes from the `AZURE_*` GitHub environment **variables**; plan-time secrets are declared via the `tf_var_secrets` input and fetched from the platform Key Vault after OIDC login. No `secrets:` block.
- **`terraform.yml`** - deploy workflow (plan/apply/destroy for `prd`). OIDC login with `vars.AZURE_*`, then the shared `keyvault-secrets` composite action exports `TF_VAR_*` values from `kv-platform-{env}-uks-02`. State plumbing is delegated to the shared composite actions.
- **`tag.yml`** - auto-tag on PR merge via shared `reusable-tag.yml` (`major/**`/`minor/**`/`patch/**` branch prefix drives the semver bump).

## Architecture

### Naming convention

`{type}-{workload}-{env}-{region}-{index}` via `local.resource_suffix` (e.g. `vnet-platform-prd-uks-01`). Flat variant `local.resource_suffix_flat` for resources that disallow hyphens (e.g. storage accounts).

### Providers

- `hashicorp/azurerm ~> 4.68.0` - all Azure resources
- `cloudflare/cloudflare ~> 5.0` - Cloudflare public DNS zones and zone settings
- `kyswtn/porkbun ~> 0.1.3` - delegates nameservers at Porkbun registrar to Cloudflare nameservers

Sensitive provider variables (`cloudflare_api_token`, `porkbun_api_key`, `porkbun_secret_api_key`, ...) are fetched from the platform Key Vault in CI and exported as `TF_VAR_*`.

### State backend

Azure Storage with azurerm backend. Resource group `rg-platform-prd-uks-01`, storage account `stplatformprduks02`. Container name matches repository name (`infra-landingzone-platform`). Single state file covers all resources. The same resource group also holds the platform Key Vault `kv-platform-prd-uks-02` (`dev` equivalents exist for the other repos).

### Tfvars layout

- `infra/vars/globals.tfvars` - empty (reserved for cross-env shared values)
- `infra/vars/prd.tfvars` - production values (subscriptions, networking, DNS, budgets)

### Resource domains

| File                   | What it manages                                                                         |
| ---------------------- | --------------------------------------------------------------------------------------- |
| `management-groups.tf` | Three MGs (Platform, Personal, Customer) under tenant root + subscription associations  |
| `networking.tf`        | Hub VNet, subnets (data-driven from `var.subnets`), NSGs, route tables, network watcher |
| `dns.tf`               | Cloudflare public DNS zones + Porkbun NS delegation                                     |
| `budgets.tf`           | GBP 2/mo consumption budget per subscription with email alerts                          |

### Deployment identity model

Platform SP (`spn-platform`) has Owner on tenant root management group - required for MG and cross-subscription operations. Personal and customer SPs have Owner scoped to their respective subscriptions. All SPs hold `Storage Account Contributor` on the tfstate storage accounts and `Key Vault Secrets User` on the platform Key Vaults.
