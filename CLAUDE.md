# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

Terraform root module for the Sky Haven Azure landing zone platform layer. Provisions management group hierarchy, hub networking (VNet, subnets, NSGs, route tables, network watcher), public DNS with Porkbun nameserver delegation, and per-subscription consumption budgets.

## Commands

### Local plan

Prerequisites: `az login` and the secret Terraform variables exported for local use.

```bash
export TF_VAR_cloudflare_api_token="<cloudflare-api-token>"
export TF_VAR_cloudflare_account_id="<cloudflare-account-id>"
export TF_VAR_porkbun_api_key="<porkbun-api-key>"
export TF_VAR_porkbun_secret_api_key="<porkbun-secret-api-key>"

terraform -chdir=infra init \
  -backend-config="resource_group_name=rg-tfs-platform-prd-uks-01" \
  -backend-config="storage_account_name=sttfsplatformprduks01" \
  -backend-config="container_name=infra-landingzone-platform" \
  -backend-config="key=terraform.tfstate" \
  -backend-config="subscription_id=<platform-subscription-id>"

terraform -chdir=infra plan  -var-file="vars/globals.tfvars" -var-file="vars/prd.tfvars"
terraform -chdir=infra apply -var-file="vars/globals.tfvars" -var-file="vars/prd.tfvars"
```

### Bootstrap scripts (one-time, not Terraform-managed)

- `scripts/bootstrap-tfstate-backend.sh` - creates resource groups and storage accounts for Terraform remote state
- `scripts/bootstrap-deployment-identities.sh` - creates OIDC service principals and role assignments

## Pipeline Behaviour

Pipelines consume shared reusable workflows and composite actions from `skyhaven-ltd/pipeline-engineering-github-actions`, SHA-pinned to a released tag.

**`lint.yml`** - runs on every PR to `main`. Calls the shared `reusable-lint.yml` (MegaLinter, `terraform` flavour); tune it via `.github/validation/.mega-linter.yml`. Terraform IaC scanning lives in `pr-validation.yml`, not here.

**`pr-validation.yml`** - runs on PRs to `main` (excluding `**/*.md` and `docs/**` changes). Calls the shared `reusable-terraform.yml`, which runs Terraform hygiene (`fmt`, backendless `init`, `validate`, TFLint) and zizmor workflow-security scanning, then runs a real `prd` Terraform plan using the `prd` GitHub Environment, Azure OIDC, remote state, Checkov plan-aware deep analysis, and an Infracost sticky comment after Checkov passes. Checkov findings fail the run unless centrally suppressed. Plan-time secret variables are supplied through the `TF_VARS_JSON` environment secret.

**`terraform.yml`** - deploy workflow. Triggers on push to `major/**`, `minor/**`, `patch/**` branches that touch `infra/**`, or via `workflow_dispatch` (env: `prd`, action: plan/apply/destroy). Defaults to `prd` + `plan`. Authenticates to Azure via OIDC (no client secret). State plumbing - ensure container, backend init, break lease - is delegated to the shared composite actions.

**`tag.yml`** - auto-tags on PR merge via the shared `reusable-tag.yml`. Branch prefix drives semver bump: `major/**` -> major, `minor/**` -> minor, `patch/**` -> patch. Other prefixes produce no tag.

## Architecture

### Naming convention

`{type}-{workload}-{env}-{region}-{index}` via `local.resource_suffix` (e.g. `vnet-platform-prd-uks-01`). Built from `var.workload`, `var.environment`, `var.location_short`, and `var.instance`. Flat variant `local.resource_suffix_flat` used for resources that disallow hyphens (e.g. storage accounts).

### Providers

- `hashicorp/azurerm ~> 4.68.0` - all Azure resources
- `cloudflare/cloudflare ~> 5.0` - Cloudflare public DNS zones and zone settings
- `kyswtn/porkbun ~> 0.1.3` - delegates nameservers at Porkbun registrar to Cloudflare nameservers

Porkbun provider authentication is wired through sensitive Terraform variables (`porkbun_api_key`, `porkbun_secret_api_key`). In CI, PR plans receive them through `TF_VARS_JSON`; the deploy workflow maps the existing `PORKBUN_API_KEY` and `PORKBUN_SECRET_API_KEY` environment secrets to `TF_VAR_porkbun_api_key` and `TF_VAR_porkbun_secret_api_key`.

### State backend

Azure Storage with azurerm backend. Resource group `rg-tfs-platform-prd-uks-01`, storage account `sttfsplatformprduks01`. Container name matches repository name (`infra-landingzone-platform`). Single state file covers all resources.

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
