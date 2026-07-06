#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# bootstrap-platform.sh
#
# Single idempotent bootstrap for the Sky Haven platform layer. Creates, per
# environment, one resource group (rg-platform-{env}-uks-01) holding the
# Terraform state storage account and the platform Key Vault, then the OIDC
# deployment identities (service principals, federated credentials, role
# assignments) and the GitHub environments/variables the workflows consume.
#
# These resources are intentionally not managed by Terraform (bootstrap).
#
# The platform Key Vaults are the source of truth for workflow secrets:
# workflows OIDC-login with GitHub environment variables (AZURE_* IDs), then
# read named secrets from kv-platform-{env}-uks-02. The executing user is
# granted Key Vault Secrets Officer so secrets stay readable and rotatable.
#
# Prerequisites: az CLI, gh CLI, authenticated sessions
#   az login
#   gh auth login
#
# Safe to re-run at any time; every step is create-or-skip/enforce.
# If the storage account or Key Vault exists in a different resource group,
# the script prints the `az resource move` commands and exits — it never
# moves resources itself.
#
# Naming schema: {type}-{workload}-{env}-{region}-{index}
# The RG uses instance 01; the storage account and Key Vault use instance 02
# because their names are globally unique and the 01 forms are taken by
# third parties (verified 2026-07-06).
###############################################################################

TENANT_ID="bcfa57b3-7ca9-479a-bd62-2d2894d69ee4"
GITHUB_OWNER="skyhaven-ltd"
PLATFORM_SUB="cefc8742-e1dd-4b24-90a9-07e3d3c80d88" # Hosts state + Key Vaults

WORKLOAD="platform"
LOCATION="uksouth"
LOCATION_SHORT="uks"
RG_INSTANCE="01"       # Resource group (subscription-scoped, no collisions)
RESOURCE_INSTANCE="02" # Storage account + Key Vault (globally unique names)
ENVIRONMENTS=("prd" "dev")

ROLE="Owner" # Owner required for Terraform to manage role assignments
TFSTATE_ROLE="Storage Account Contributor"
KEYVAULT_SPN_ROLE="Key Vault Secrets User"     # Data-plane read for pipelines
KEYVAULT_USER_ROLE="Key Vault Secrets Officer" # Data-plane read/write for the operator
KEYVAULT_SOFT_DELETE_RETENTION_DAYS=90

declare -A SUBSCRIPTION_IDS=(
	["platform"]="cefc8742-e1dd-4b24-90a9-07e3d3c80d88"
	["personal"]="48a8b708-dc42-468f-97bc-fd949c073eb8"
	["customer"]="1c26c084-763b-4d2d-86aa-af36b444b6bb"
)

# "managementgroup" = tenant root group (TENANT_ID); "subscription" = subscription scope
declare -A ROLE_ASSIGNMENT_SCOPES=(
	["platform"]="managementgroup"
	["personal"]="subscription"
	["customer"]="subscription"
)

# Map each scope to the repos and environments that need federated credentials.
# Format: "repo:environment" pairs. Each pair gets its own federated credential.
declare -A GITHUB_REPOS=(
	["platform"]="infra-landingzone-platform:prd"
	["personal"]="app-certwatch-web:dev app-certwatch-web:prd app-cvengine-portfolio:dev app-cvengine-portfolio:prd app-powertoggle-vm:dev app-powertoggle-vm:prd infra-engineering-template:dev infra-engineering-template:prd"
	["customer"]="app-braveart-gallery:dev app-braveart-gallery:prd"
)

SCOPES=("platform" "personal" "customer")

rg_name() { echo "rg-${WORKLOAD}-${1}-${LOCATION_SHORT}-${RG_INSTANCE}"; }
st_name() { echo "st${WORKLOAD}${1}${LOCATION_SHORT}${RESOURCE_INSTANCE}"; }
kv_name() { echo "kv-${WORKLOAD}-${1}-${LOCATION_SHORT}-${RESOURCE_INSTANCE}"; }

###############################################################################
# Helpers
###############################################################################

new_guid() {
	if command -v powershell >/dev/null 2>&1; then
		powershell -NoProfile -Command "[guid]::NewGuid().ToString()"
	elif command -v uuidgen >/dev/null 2>&1; then
		uuidgen
	else
		cat /proc/sys/kernel/random/uuid
	fi
}

# ARM REST role assignment (management groups, subscriptions, storage accounts)
ensure_role_assignment() {
	local arm_scope="$1"
	local role_name="$2"
	local principal_id="$3"
	local principal_type="$4"
	local scope_description="$5"
	local role_def_id
	local existing_assignment
	local assignment_guid

	echo "Assigning ${role_name} on ${scope_description}..."

	role_def_id=$(az rest \
		--method GET \
		--uri "https://management.azure.com/${arm_scope}/providers/Microsoft.Authorization/roleDefinitions?api-version=2022-04-01&\$filter=roleName eq '${role_name}'" \
		--query "value[0].id" -o tsv)

	if [[ -z "$role_def_id" || "$role_def_id" == "None" ]]; then
		echo "Unable to find role definition '${role_name}' at scope '${arm_scope}'." >&2
		exit 1
	fi

	existing_assignment=$(az rest \
		--method GET \
		--uri "https://management.azure.com/${arm_scope}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId eq '${principal_id}'" \
		--query "value[?properties.roleDefinitionId=='${role_def_id}'] | [0].id" -o tsv 2>/dev/null)

	if [[ -n "$existing_assignment" && "$existing_assignment" != "None" ]]; then
		echo "Role assignment already exists on ${scope_description}, skipping."
	else
		assignment_guid=$(new_guid)
		az rest \
			--method PUT \
			--uri "https://management.azure.com/${arm_scope}/providers/Microsoft.Authorization/roleAssignments/${assignment_guid}?api-version=2022-04-01" \
			--body "{
        \"properties\": {
          \"roleDefinitionId\": \"${role_def_id}\",
          \"principalId\": \"${principal_id}\",
          \"principalType\": \"${principal_type}\"
        }
      }" \
			--output none
	fi
}

# CLI role assignment (Key Vault data-plane roles)
ensure_cli_role_assignment() {
	local scope="$1"
	local role_name="$2"
	local principal_id="$3"
	local principal_type="$4"
	local scope_description="$5"
	local existing_assignment

	echo "Assigning ${role_name} on ${scope_description}..."

	existing_assignment=$(MSYS_NO_PATHCONV=1 az role assignment list \
		--assignee-object-id "$principal_id" \
		--role "$role_name" \
		--scope "$scope" \
		--query "[0].id" \
		--output tsv 2>/dev/null)

	if [[ -n "$existing_assignment" && "$existing_assignment" != "None" ]]; then
		echo "Role assignment already exists on ${scope_description}, skipping."
	else
		MSYS_NO_PATHCONV=1 az role assignment create \
			--assignee-object-id "$principal_id" \
			--assignee-principal-type "$principal_type" \
			--role "$role_name" \
			--scope "$scope" \
			--output none
	fi
}

###############################################################################
# Preflight
###############################################################################

for cmd in az gh; do
	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "Required command '${cmd}' not found." >&2
		exit 1
	fi
done

USER_OBJ_ID=$(az ad signed-in-user show --query id -o tsv)
echo "Executing user object ID: ${USER_OBJ_ID}"
echo ""

###############################################################################
# Part 1 — Platform resources (per environment)
###############################################################################

MOVE_REQUIRED=0

for ENV in "${ENVIRONMENTS[@]}"; do
	RG_NAME=$(rg_name "$ENV")
	ST_NAME=$(st_name "$ENV")
	KV_NAME=$(kv_name "$ENV")

	echo "=== ${ENV} platform resources ==="
	echo "Resource group:  ${RG_NAME}"
	echo "Storage account: ${ST_NAME}"
	echo "Key Vault:       ${KV_NAME}"
	echo ""

	# Resource group
	echo "Creating resource group ${RG_NAME}..."
	az group create \
		--name "$RG_NAME" \
		--location "$LOCATION" \
		--tags managed-by="azure cli" \
		--subscription "$PLATFORM_SUB" \
		--output none

	# Resource group delete lock
	echo "Applying delete lock to ${RG_NAME}..."
	az lock create \
		--name "delete-lock" \
		--lock-type CanNotDelete \
		--resource-group "$RG_NAME" \
		--subscription "$PLATFORM_SUB" \
		--output none

	# Relocation guard: storage account or Key Vault living in another resource
	# group (pre-consolidation layout) must be moved, never recreated.
	EXISTING_ST_RG=$(az storage account show \
		--name "$ST_NAME" \
		--subscription "$PLATFORM_SUB" \
		--query resourceGroup \
		--output tsv 2>/dev/null || true)
	EXISTING_KV_RG=$(az keyvault show \
		--name "$KV_NAME" \
		--subscription "$PLATFORM_SUB" \
		--query resourceGroup \
		--output tsv 2>/dev/null || true)

	if [[ -n "$EXISTING_ST_RG" && "$EXISTING_ST_RG" != "None" && "$EXISTING_ST_RG" != "$RG_NAME" ]]; then
		echo "Storage account ${ST_NAME} exists in ${EXISTING_ST_RG}, expected ${RG_NAME}." >&2
		echo "Move it (after removing any delete locks on ${EXISTING_ST_RG}):" >&2
		echo "  az lock delete --name delete-lock --resource-group ${EXISTING_ST_RG} --subscription ${PLATFORM_SUB}" >&2
		echo "  az resource move --destination-group ${RG_NAME} --ids \$(az storage account show -n ${ST_NAME} -g ${EXISTING_ST_RG} --subscription ${PLATFORM_SUB} --query id -o tsv)" >&2
		MOVE_REQUIRED=1
	fi

	if [[ -n "$EXISTING_KV_RG" && "$EXISTING_KV_RG" != "None" && "$EXISTING_KV_RG" != "$RG_NAME" ]]; then
		echo "Key Vault ${KV_NAME} exists in ${EXISTING_KV_RG}, expected ${RG_NAME}." >&2
		echo "Move it (after removing any delete locks on ${EXISTING_KV_RG}):" >&2
		echo "  az lock delete --name delete-lock --resource-group ${EXISTING_KV_RG} --subscription ${PLATFORM_SUB}" >&2
		echo "  az resource move --destination-group ${RG_NAME} --ids \$(az keyvault show -n ${KV_NAME} -g ${EXISTING_KV_RG} --subscription ${PLATFORM_SUB} --query id -o tsv)" >&2
		MOVE_REQUIRED=1
	fi

	if [[ "$MOVE_REQUIRED" -eq 1 ]]; then
		echo "" >&2
		echo "Rerun this script after moving the resources above into ${RG_NAME}." >&2
		exit 1
	fi

	# Storage account
	if [[ "$EXISTING_ST_RG" == "$RG_NAME" ]]; then
		echo "Storage account ${ST_NAME} already exists, skipping creation."
	else
		echo "Creating storage account ${ST_NAME}..."
		az storage account create \
			--name "$ST_NAME" \
			--resource-group "$RG_NAME" \
			--location "$LOCATION" \
			--sku Standard_LRS \
			--kind StorageV2 \
			--min-tls-version TLS1_2 \
			--allow-blob-public-access false \
			--https-only true \
			--subscription "$PLATFORM_SUB" \
			--output none
	fi

	# Storage account settings and tags (enforced on every run)
	echo "Enforcing settings and tags on ${ST_NAME}..."
	az storage account update \
		--name "$ST_NAME" \
		--resource-group "$RG_NAME" \
		--tags managed-by="azure cli" \
		--min-tls-version TLS1_2 \
		--allow-blob-public-access false \
		--https-only true \
		--public-network-access Enabled \
		--subscription "$PLATFORM_SUB" \
		--output none

	# Blob versioning and soft delete for state protection
	echo "Enabling blob versioning and soft delete..."
	az storage account blob-service-properties update \
		--account-name "$ST_NAME" \
		--resource-group "$RG_NAME" \
		--enable-versioning true \
		--enable-delete-retention true \
		--delete-retention-days 30 \
		--enable-container-delete-retention true \
		--container-delete-retention-days 30 \
		--subscription "$PLATFORM_SUB" \
		--output none

	# Key Vault
	if [[ "$EXISTING_KV_RG" == "$RG_NAME" ]]; then
		echo "Key Vault ${KV_NAME} already exists, skipping creation."
	else
		echo "Creating Key Vault ${KV_NAME}..."
		az keyvault create \
			--name "$KV_NAME" \
			--resource-group "$RG_NAME" \
			--location "$LOCATION" \
			--sku standard \
			--enable-rbac-authorization true \
			--enable-purge-protection true \
			--retention-days "$KEYVAULT_SOFT_DELETE_RETENTION_DAYS" \
			--public-network-access Enabled \
			--default-action Allow \
			--bypass AzureServices \
			--tags managed-by="azure cli" \
			--subscription "$PLATFORM_SUB" \
			--output none
	fi

	# Key Vault settings (enforced on every run)
	echo "Ensuring Key Vault settings on ${KV_NAME}..."
	az keyvault update \
		--name "$KV_NAME" \
		--resource-group "$RG_NAME" \
		--enable-rbac-authorization true \
		--enable-purge-protection true \
		--public-network-access Enabled \
		--default-action Allow \
		--bypass AzureServices \
		--subscription "$PLATFORM_SUB" \
		--output none

	KV_ID=$(az keyvault show \
		--name "$KV_NAME" \
		--resource-group "$RG_NAME" \
		--subscription "$PLATFORM_SUB" \
		--query id \
		--output tsv)

	echo "Applying tags to ${KV_NAME}..."
	MSYS_NO_PATHCONV=1 az resource tag \
		--ids "$KV_ID" \
		--tags managed-by="azure cli" \
		--output none

	# Operator read/write access so secrets stay viewable and rotatable
	ensure_cli_role_assignment "$KV_ID" "$KEYVAULT_USER_ROLE" "$USER_OBJ_ID" "User" "${KV_NAME} (executing user)"

	echo "Done."
	echo ""
done

###############################################################################
# Part 2 — Deployment identities (per scope)
###############################################################################

for SCOPE in "${SCOPES[@]}"; do
	SUB_ID="${SUBSCRIPTION_IDS[$SCOPE]}"
	SP_NAME="spn-${SCOPE}"

	echo "=== ${SCOPE} deployment identity ==="
	echo "Service principal: ${SP_NAME}"
	echo "Subscription:      ${SUB_ID}"
	echo ""

	# App registration (idempotent — reuse if exists)
	echo "Creating app registration..."
	EXISTING_APP_ID=$(az ad app list --display-name "$SP_NAME" --query "[0].appId" -o tsv 2>/dev/null)
	if [[ -n "$EXISTING_APP_ID" && "$EXISTING_APP_ID" != "None" ]]; then
		APP_ID="$EXISTING_APP_ID"
		echo "App already exists, reusing App ID: ${APP_ID}"
	else
		APP_ID=$(az ad app create \
			--display-name "$SP_NAME" \
			--query appId \
			--output tsv)
		echo "App ID: ${APP_ID}"
	fi

	# Service principal for the app (idempotent)
	echo "Creating service principal..."
	if ! az ad sp show --id "$APP_ID" --output none 2>/dev/null; then
		az ad sp create --id "$APP_ID" --output none
	else
		echo "Service principal already exists, skipping."
	fi

	# Role assignment — scope varies per identity:
	#   managementgroup → tenant root group (landing zone deployments require this)
	#   subscription    → subscription scope
	SP_OBJ_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)
	if [[ "${ROLE_ASSIGNMENT_SCOPES[$SCOPE]}" == "managementgroup" ]]; then
		ARM_SCOPE="providers/Microsoft.Management/managementGroups/${TENANT_ID}"
		ARM_SCOPE_DESCRIPTION="tenant root management group"
	else
		ARM_SCOPE="subscriptions/${SUB_ID}"
		ARM_SCOPE_DESCRIPTION="subscription ${SUB_ID}"
	fi

	ensure_role_assignment "$ARM_SCOPE" "$ROLE" "$SP_OBJ_ID" "ServicePrincipal" "$ARM_SCOPE_DESCRIPTION"

	# Storage Account Contributor on the tfstate storage accounts and
	# Key Vault Secrets User on the platform vaults, both environments
	for ENV in "${ENVIRONMENTS[@]}"; do
		RG_NAME=$(rg_name "$ENV")
		ST_NAME=$(st_name "$ENV")
		KV_NAME=$(kv_name "$ENV")

		SA_SCOPE="subscriptions/${PLATFORM_SUB}/resourceGroups/${RG_NAME}/providers/Microsoft.Storage/storageAccounts/${ST_NAME}"
		ensure_role_assignment "$SA_SCOPE" "$TFSTATE_ROLE" "$SP_OBJ_ID" "ServicePrincipal" "$ST_NAME"

		KV_ID=$(az keyvault show \
			--name "$KV_NAME" \
			--resource-group "$RG_NAME" \
			--subscription "$PLATFORM_SUB" \
			--query id \
			--output tsv)
		ensure_cli_role_assignment "$KV_ID" "$KEYVAULT_SPN_ROLE" "$SP_OBJ_ID" "ServicePrincipal" "$KV_NAME"
	done

	# GitHub Actions federated credentials (one per repo/environment pair)
	REPO_ENTRIES="${GITHUB_REPOS[$SCOPE]}"
	if [[ -z "$REPO_ENTRIES" ]]; then
		echo "No GitHub repos configured for this scope, skipping federated credentials."
	else
		for ENTRY in $REPO_ENTRIES; do
			REPO="${ENTRY%%:*}"
			ENV="${ENTRY##*:}"
			FC_NAME="fc-${REPO}-${ENV}"
			FC_SUBJECT="repo:${GITHUB_OWNER}/${REPO}:environment:${ENV}"

			echo "Adding federated credential: ${FC_NAME} (${FC_SUBJECT})..."

			EXISTING_CRED=$(az ad app federated-credential list --id "$APP_ID" --query "[?name=='${FC_NAME}'] | [0].id" -o tsv 2>/dev/null)
			if [[ -n "$EXISTING_CRED" && "$EXISTING_CRED" != "None" ]]; then
				echo "Federated credential already exists, skipping."
			else
				az ad app federated-credential create \
					--id "$APP_ID" \
					--parameters "{
            \"name\": \"${FC_NAME}\",
            \"issuer\": \"https://token.actions.githubusercontent.com\",
            \"subject\": \"${FC_SUBJECT}\",
            \"audiences\": [\"api://AzureADTokenExchange\"]
          }" \
					--output none
			fi

			# Ensure GitHub environment exists (idempotent — PUT creates or no-ops)
			gh api --method PUT "repos/${GITHUB_OWNER}/${REPO}/environments/${ENV}" --silent 2>/dev/null || true

			# GitHub environment *variables* — the OIDC identifiers are GUIDs, not
			# secrets, and variables stay viewable in the UI. gh variable set is
			# an idempotent overwrite.
			echo "Setting GitHub environment variables on ${GITHUB_OWNER}/${REPO} (${ENV})..."
			gh variable set AZURE_CLIENT_ID --repo "${GITHUB_OWNER}/${REPO}" --env "${ENV}" --body "$APP_ID"
			gh variable set AZURE_TENANT_ID --repo "${GITHUB_OWNER}/${REPO}" --env "${ENV}" --body "$TENANT_ID"
			gh variable set AZURE_SUBSCRIPTION_ID --repo "${GITHUB_OWNER}/${REPO}" --env "${ENV}" --body "$SUB_ID"
			gh variable set AZURE_PLATFORM_SUBSCRIPTION_ID --repo "${GITHUB_OWNER}/${REPO}" --env "${ENV}" --body "$PLATFORM_SUB"

			# Remove the legacy environment secrets these variables replace
			for SECRET_NAME in AZURE_CLIENT_ID AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID AZURE_PLATFORM_SUBSCRIPTION_ID; do
				gh secret delete "$SECRET_NAME" --repo "${GITHUB_OWNER}/${REPO}" --env "${ENV}" 2>/dev/null || true
			done
		done
	fi

	echo "Done."
	echo ""
done

###############################################################################
# Part 3 — spn-platform Graph API permissions
#
# Required so the azuread Terraform provider can look up service principals
# by display name during plan/apply. Cannot be managed by Terraform itself
# as it is a prerequisite for the provider to authenticate and query AD.
###############################################################################

echo "=== spn-platform Graph API permissions ==="

GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"    # Microsoft Graph
APP_READ_ALL_ID="9a5d68dd-52b0-4cc2-bd40-abcf44ac3a30" # Application.Read.All (application permission)

PLATFORM_APP_ID=$(az ad app list --display-name "spn-platform" --query "[0].appId" -o tsv)

EXISTING_PERMISSION=$(az ad app permission list --id "$PLATFORM_APP_ID" \
	--query "[?resourceAppId=='${GRAPH_APP_ID}'].resourceAccess[?id=='${APP_READ_ALL_ID}'] | [0].id" \
	-o tsv 2>/dev/null)

if [[ -n "$EXISTING_PERMISSION" && "$EXISTING_PERMISSION" != "None" ]]; then
	echo "Application.Read.All already granted, skipping."
else
	echo "Adding Application.Read.All permission..."
	az ad app permission add \
		--id "$PLATFORM_APP_ID" \
		--api "$GRAPH_APP_ID" \
		--api-permissions "${APP_READ_ALL_ID}=Role" \
		--output none
fi

echo "Granting admin consent for Application.Read.All..."
az ad app permission admin-consent --id "$PLATFORM_APP_ID" --output none

echo "Done."
echo ""

###############################################################################
# Part 4 — Summary
###############################################################################

echo "All platform resources and deployment identities are in place."
echo ""
echo "Terraform backend configuration:"
echo ""
for ENV in "${ENVIRONMENTS[@]}"; do
	cat <<EOF
  # ${ENV}
  backend "azurerm" {
    resource_group_name  = "$(rg_name "$ENV")"
    storage_account_name = "$(st_name "$ENV")"
    container_name       = "<container>"
    key                  = "<stack>.tfstate"
  }

EOF
done

cat <<'EOF'
Expected Key Vault secrets (populate with `az keyvault secret set
--vault-name <vault> --name <name> --value '<value>'`):

  Shared (both vaults):
    cloudflare-api-token
    cloudflare-account-id
    infracost-api-key

  Shared (prd vault only is sufficient):
    porkbun-api-key
    porkbun-secret-api-key

  Repo-specific:
    braveart-yoco-secret-key            (both vaults)
    certwatch-entra-client-secret       (both vaults)
    certwatch-brevo-api-key             (both vaults)
    cvengine-blog-notify-secret         (both vaults)
    cvengine-brevo-api-key              (both vaults)
    github-platform-gh-app-id           (prd vault)
    github-platform-gh-app-private-key  (prd vault)
EOF
