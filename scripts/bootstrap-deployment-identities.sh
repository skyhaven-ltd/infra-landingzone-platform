#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# bootstrap-deployment-identities.sh
#
# Creates service principals and GitHub Actions federated credentials with OIDC
# (Workload Identity Federation) for Terraform deployments.
# One SP per subscription scope, with federated credentials per repo/environment.
#
# Prerequisites: az CLI, jq, gh CLI, authenticated session
#   az login
#   gh auth login
#
# Naming schema: spn-{scope}, fc-gha-{scope}-{repo}-{environment}
###############################################################################

TENANT_ID="bcfa57b3-7ca9-479a-bd62-2d2894d69ee4"
GITHUB_OWNER="skyhaven-ltd"
ROLE="Owner" # Owner required for Terraform to manage role assignments

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

###############################################################################

for SCOPE in "${SCOPES[@]}"; do
	SUB_ID="${SUBSCRIPTION_IDS[$SCOPE]}"
	SP_NAME="spn-${SCOPE}"

	echo "=== ${SCOPE} ==="
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
		echo "Assigning ${ROLE} on tenant root management group..."
	else
		ARM_SCOPE="subscriptions/${SUB_ID}"
		echo "Assigning ${ROLE} on subscription..."
	fi

	ROLE_DEF_ID=$(az rest \
		--method GET \
		--uri "https://management.azure.com/${ARM_SCOPE}/providers/Microsoft.Authorization/roleDefinitions?api-version=2022-04-01&\$filter=roleName eq '${ROLE}'" \
		--query "value[0].id" -o tsv)

	EXISTING_ASSIGNMENT=$(az rest \
		--method GET \
		--uri "https://management.azure.com/${ARM_SCOPE}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId eq '${SP_OBJ_ID}'" \
		--query "value[?properties.roleDefinitionId=='${ROLE_DEF_ID}'] | [0].id" -o tsv 2>/dev/null)
	if [[ -n "$EXISTING_ASSIGNMENT" && "$EXISTING_ASSIGNMENT" != "None" ]]; then
		echo "Role assignment already exists, skipping."
	else
		ASSIGNMENT_GUID=$(powershell -Command "[guid]::NewGuid().ToString()" 2>/dev/null || cat /proc/sys/kernel/random/uuid)
		az rest \
			--method PUT \
			--uri "https://management.azure.com/${ARM_SCOPE}/providers/Microsoft.Authorization/roleAssignments/${ASSIGNMENT_GUID}?api-version=2022-04-01" \
			--body "{
        \"properties\": {
          \"roleDefinitionId\": \"${ROLE_DEF_ID}\",
          \"principalId\": \"${SP_OBJ_ID}\",
          \"principalType\": \"ServicePrincipal\"
        }
      }" \
			--output none
	fi

	# Storage Account Contributor on both tfstate storage accounts
	TFSTATE_ROLE="Storage Account Contributor"
	TFSTATE_SUB="cefc8742-e1dd-4b24-90a9-07e3d3c80d88"
	TFSTATE_STORAGE_ACCOUNTS=(
		"rg-tfs-platform-prd-uks-01/sttfsplatformprduks01"
		"rg-tfs-platform-dev-uks-01/sttfsplatformdevuks01"
	)

	for SA_ENTRY in "${TFSTATE_STORAGE_ACCOUNTS[@]}"; do
		SA_RG="${SA_ENTRY%%/*}"
		SA_NAME="${SA_ENTRY##*/}"
		SA_SCOPE="subscriptions/${TFSTATE_SUB}/resourceGroups/${SA_RG}/providers/Microsoft.Storage/storageAccounts/${SA_NAME}"

		echo "Assigning ${TFSTATE_ROLE} on ${SA_NAME}..."

		SA_ROLE_DEF_ID=$(az rest \
			--method GET \
			--uri "https://management.azure.com/${SA_SCOPE}/providers/Microsoft.Authorization/roleDefinitions?api-version=2022-04-01&\$filter=roleName eq '${TFSTATE_ROLE}'" \
			--query "value[0].id" -o tsv)

		SA_EXISTING=$(az rest \
			--method GET \
			--uri "https://management.azure.com/${SA_SCOPE}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId eq '${SP_OBJ_ID}'" \
			--query "value[?properties.roleDefinitionId=='${SA_ROLE_DEF_ID}'] | [0].id" -o tsv 2>/dev/null)

		if [[ -n "$SA_EXISTING" && "$SA_EXISTING" != "None" ]]; then
			echo "Role assignment already exists on ${SA_NAME}, skipping."
		else
			SA_ASSIGNMENT_GUID=$(powershell -Command "[guid]::NewGuid().ToString()" 2>/dev/null || cat /proc/sys/kernel/random/uuid)
			az rest \
				--method PUT \
				--uri "https://management.azure.com/${SA_SCOPE}/providers/Microsoft.Authorization/roleAssignments/${SA_ASSIGNMENT_GUID}?api-version=2022-04-01" \
				--body "{
          \"properties\": {
            \"roleDefinitionId\": \"${SA_ROLE_DEF_ID}\",
            \"principalId\": \"${SP_OBJ_ID}\",
            \"principalType\": \"ServicePrincipal\"
          }
        }" \
				--output none
		fi
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

			# Set repo secrets (idempotent — gh secret set overwrites safely)
			echo "Setting GitHub secrets on ${GITHUB_OWNER}/${REPO}..."
			echo "$APP_ID" | gh secret set AZURE_CLIENT_ID --repo "${GITHUB_OWNER}/${REPO}" --env "${ENV}"
			echo "$TENANT_ID" | gh secret set AZURE_TENANT_ID --repo "${GITHUB_OWNER}/${REPO}" --env "${ENV}"
			echo "$SUB_ID" | gh secret set AZURE_SUBSCRIPTION_ID --repo "${GITHUB_OWNER}/${REPO}" --env "${ENV}"
			echo "$TFSTATE_SUB" | gh secret set AZURE_PLATFORM_SUBSCRIPTION_ID --repo "${GITHUB_OWNER}/${REPO}" --env "${ENV}"
		done
	fi

	echo "Done."
	echo ""
done

###############################################################################
# Grant spn-platform Application.Read.All on Microsoft Graph
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

echo "All service principals and federated credentials created successfully."
