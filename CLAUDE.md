# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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

- `scripts/bootstrap-platform.sh` - single script creating, per environment, the platform resource group (`rg-platform-{env}-uks-01`) with delete lock, tfstate storage account, platform Key Vault, OIDC service principals with federated credentials and role assignments, GitHub environments, and the `AZURE_*` GitHub environment variables. Safe to re-run; if the storage account or Key Vault lives in a different resource group it prints `az resource move` commands and exits.

## Pipeline Behaviour

Pipelines consume shared reusable workflows and composite actions from `skyhaven-ltd/pipeline-engineering-github-actions`, SHA-pinned to a released tag.

**`lint.yml`** - runs on every PR to `main`. Calls the shared `reusable-lint.yml` (MegaLinter, `terraform` flavour); tune it via `.github/validation/.mega-linter.yml`. Terraform IaC scanning lives in `pr-validation.yml`, not here.

**`pr-validation.yml`** - runs on PRs to `main` (excluding `**/*.md` and `docs/**` changes). Calls the shared `reusable-terraform.yml`, which runs Terraform hygiene (`fmt`, backendless `init`, `validate`, TFLint) and zizmor workflow-security scanning, then runs a real `prd` Terraform plan using the `prd` GitHub Environment, Azure OIDC, remote state, Checkov plan-aware deep analysis, and an Infracost sticky comment after Checkov passes. Checkov findings fail the run unless centrally suppressed. Plan-time secret variables are declared via the `tf_var_secrets` input (`TF_VAR_name=kv-secret-name` lines) and fetched from the platform Key Vault after OIDC login; there is no `secrets:` block or `secrets: inherit`.

**`terraform.yml`** - deploy workflow. Triggers on push to `major/**`, `minor/**`, `patch/**` branches that touch `infra/**`, or via `workflow_dispatch` (env: `prd`, action: plan/apply/destroy). Defaults to `prd` + `plan`. Authenticates to Azure via OIDC using the `AZURE_*` GitHub environment **variables** (no client secret; the IDs are GUIDs, viewable in the UI), then fetches Terraform secrets from `kv-platform-{env}-uks-02` via the shared `keyvault-secrets` composite action. State plumbing - ensure container, backend init, break lease - is delegated to the shared composite actions.

**`tag.yml`** - auto-tags on PR merge via the shared `reusable-tag.yml`. Branch prefix drives semver bump: `major/**` -> major, `minor/**` -> minor, `patch/**` -> patch. Other prefixes produce no tag.

## Architecture

### Naming convention

`{type}-{workload}-{env}-{region}-{index}` via `local.resource_suffix` (e.g. `vnet-platform-prd-uks-01`). Built from `var.workload`, `var.environment`, `var.location_short`, and `var.instance`. Flat variant `local.resource_suffix_flat` used for resources that disallow hyphens (e.g. storage accounts).

### Providers

- `hashicorp/azurerm ~> 4.68.0` - all Azure resources
- `cloudflare/cloudflare ~> 5.0` - Cloudflare public DNS zones and zone settings
- `kyswtn/porkbun ~> 0.1.3` - delegates nameservers at Porkbun registrar to Cloudflare nameservers

Porkbun provider authentication is wired through sensitive Terraform variables (`porkbun_api_key`, `porkbun_secret_api_key`). In CI, both PR plans and deploys fetch them from the platform Key Vault (`porkbun-api-key`, `porkbun-secret-api-key` in `kv-platform-prd-uks-02`) after OIDC login and export them as `TF_VAR_*`.

### State backend

Azure Storage with azurerm backend. Resource group `rg-platform-prd-uks-01`, storage account `stplatformprduks02`. Container name matches repository name (`infra-landingzone-platform`). Single state file covers all resources. The same resource group also holds the platform Key Vault `kv-platform-prd-uks-02` (`dev` equivalents exist for the other repos).

### Tfvars layout

Flat structure under `infra/vars/`:

- `globals.tfvars` - empty (reserved for cross-env shared values)
- `prd.tfvars` - production values (subscriptions, networking, DNS, budgets)

### CI/CD (GitHub Actions)

See **Pipeline Behaviour** above for the current shared workflow layout. Do not reintroduce repo-local copies of the Terraform state composite actions; consume the pinned shared composites instead.

### Resource domains

| File                   | What it manages                                                                         |
| ---------------------- | --------------------------------------------------------------------------------------- |
| `management-groups.tf` | Three MGs (Platform, Personal, Customer) under tenant root + subscription associations  |
| `networking.tf`        | Hub VNet, subnets (data-driven from `var.subnets`), NSGs, route tables, network watcher |
| `dns.tf`               | Cloudflare public DNS zones + Porkbun NS delegation                                     |
| `budgets.tf`           | GBP 2/mo consumption budget per subscription with email alerts                         |

### Deployment identity model

Platform SP (`spn-platform`) has Owner on tenant root management group - required for MG and cross-subscription operations. Personal and customer SPs have Owner scoped to their respective subscriptions.
