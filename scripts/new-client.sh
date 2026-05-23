#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# new-client.sh — scaffold a new client folder from clients/_template/
#
# Usage:
#   bash scripts/new-client.sh <client-id> [domain]
#
# Example:
#   bash scripts/new-client.sh acme-corp acme.com
#
# What it does:
#   1. Copies clients/_template/ to clients/<client-id>/
#   2. Substitutes __CLIENT_ID__ and __DOMAIN__ placeholders in the copy
#   3. Renames package.json names to @clients/<id>-{landing,api,dashboard}
#   4. Prints next steps (Terraform block to add, GitHub secrets to configure)
# ---------------------------------------------------------------------------

set -euo pipefail

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <client-id> [domain]"
  echo "  client-id: lowercase letters, digits, dashes (e.g. 'acme-corp')"
  echo "  domain:    apex domain for the landing page (optional, defaults to <id>.example.com)"
  exit 1
fi

CLIENT_ID="$1"
DOMAIN="${2:-${CLIENT_ID}.example.com}"

# Validate client ID — must be safe for use in resource names everywhere
if ! [[ "$CLIENT_ID" =~ ^[a-z][a-z0-9-]{1,30}$ ]]; then
  echo "Error: client-id must match ^[a-z][a-z0-9-]{1,30}$"
  echo "       (lowercase letters, digits, dashes; starts with a letter; max 31 chars)"
  exit 1
fi

# -----------------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------------

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE_DIR="$REPO_ROOT/clients/_template"
TARGET_DIR="$REPO_ROOT/clients/$CLIENT_ID"

if [[ ! -d "$TEMPLATE_DIR" ]]; then
  echo "Error: template directory not found at $TEMPLATE_DIR"
  exit 1
fi

if [[ -d "$TARGET_DIR" ]]; then
  echo "Error: client directory already exists at $TARGET_DIR"
  echo "       Choose a different client-id or remove the existing folder."
  exit 1
fi

# -----------------------------------------------------------------------------
# Copy template -> target
# -----------------------------------------------------------------------------

echo "→ Copying template to $TARGET_DIR"
cp -r "$TEMPLATE_DIR" "$TARGET_DIR"

# -----------------------------------------------------------------------------
# Substitute placeholders in every file
# Uses portable sed invocation that works on both GNU sed (Linux) and BSD sed (macOS)
# -----------------------------------------------------------------------------

substitute_placeholders() {
  local file="$1"
  # `sed -i ''` for macOS; `sed -i` for Linux. Detect by OS.
  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' \
      -e "s/__CLIENT_ID__/${CLIENT_ID}/g" \
      -e "s/__DOMAIN__/${DOMAIN}/g" \
      "$file"
  else
    sed -i \
      -e "s/__CLIENT_ID__/${CLIENT_ID}/g" \
      -e "s/__DOMAIN__/${DOMAIN}/g" \
      "$file"
  fi
}

echo "→ Substituting placeholders"
# Only substitute in text files; skip binaries and node_modules
find "$TARGET_DIR" \
  -type f \
  \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.json" \
     -o -name "*.md" -o -name "*.html" -o -name "*.yml" -o -name "*.yaml" \
     -o -name "Dockerfile" -o -name ".env.example" -o -name "*.prisma" \) \
  -not -path "*/node_modules/*" \
  -print0 | while IFS= read -r -d '' file; do
    substitute_placeholders "$file"
  done

# -----------------------------------------------------------------------------
# Done — print next steps
# -----------------------------------------------------------------------------

cat <<EOF

✓ Scaffolded client: ${CLIENT_ID}
✓ Domain:            ${DOMAIN}
✓ Location:          clients/${CLIENT_ID}/

Next steps:

  1. Edit clients/${CLIENT_ID}/client.config.ts with the customer's branding and copy.

  2. Add a Terraform block to infra/terraform/clients.tf:

       module "${CLIENT_ID//-/_}" {
         source = "./modules/client-stack"

         client_id           = "${CLIENT_ID}"
         domain              = "${DOMAIN}"
         project_id          = var.project_id
         region              = var.region
         vpc_id              = module.shared.vpc_id
         db_subnet_id        = module.shared.db_subnet_id
         postgres_host       = module.shared.postgres_internal_ip
         artifact_registry   = module.shared.artifact_registry
         firebase_project_id = "${CLIENT_ID}-landing"  # Create a Firebase project with this ID
       }

  3. Apply Terraform:
       cd infra/terraform
       terraform apply

  4. Create the GitHub Actions workflow:
       cp .github/workflows/deploy-acme-corp.yml .github/workflows/deploy-${CLIENT_ID}.yml
       # Then edit it to replace 'acme-corp' with '${CLIENT_ID}'

  5. Install dependencies and verify the build works:
       pnpm install
       pnpm --filter @clients/${CLIENT_ID}-landing build
       pnpm --filter @clients/${CLIENT_ID}-api build
       pnpm --filter @clients/${CLIENT_ID}-dashboard build

  6. Push to main — CI/CD takes over from there.

EOF
