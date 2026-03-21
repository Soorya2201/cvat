#!/usr/bin/env bash
# =============================================================================
# FILE: deploy.sh
#
# Full deployment of modified CVAT (with audio) to Microsoft Azure.
# Run this from the root of your CVAT fork after building the audio image.
#
# Prerequisites:
#   - Azure CLI installed and logged in  (az login)
#   - Docker installed and running
#   - jq installed  (sudo apt-get install jq)
#
# Usage:
#   chmod +x deploy.sh
#   ./deploy.sh
# =============================================================================

set -euo pipefail

# ── Configuration — edit these if you want different names ───────────────────
RESOURCE_GROUP="cvat-everyday-respect-rg"
LOCATION="eastus"
ACR_NAME="cvateverydayrespect"          # Must be globally unique, lowercase, 5-50 chars
CONTAINER_NAME="cvat-demo"
DNS_LABEL="cvat-everyday-respect"       # Must be globally unique → becomes the hostname
PG_SERVER_NAME="cvat-postgres-er"       # Must be globally unique
PG_DB_NAME="cvat"
PG_ADMIN_USER="cvat_admin"
PG_ADMIN_PASSWORD="CvatDemo2024!"       # Change this!
STORAGE_ACCOUNT="cvatmediastorage"      # Must be globally unique, lowercase, 3-24 chars
CVAT_SUPERUSER_PASSWORD="Demo1234!"

# ── Colors for output ─────────────────────────────────────────────────────────
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${BLUE}[deploy]${NC} $1"; }
ok()   { echo -e "${GREEN}[ok]${NC} $1"; }
warn() { echo -e "${YELLOW}[warn]${NC} $1"; }

# =============================================================================
# STEP 1 — Resource Group
# =============================================================================
log "Creating resource group: $RESOURCE_GROUP in $LOCATION"
az group create \
    --name "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --output none
ok "Resource group created"

# =============================================================================
# STEP 2 — Azure Container Registry (ACR)
# =============================================================================
log "Creating Azure Container Registry: $ACR_NAME"
az acr create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ACR_NAME" \
    --sku Basic \
    --admin-enabled true \
    --output none
ok "ACR created"

# Get ACR login server and credentials
ACR_LOGIN_SERVER=$(az acr show --name "$ACR_NAME" --query loginServer --output tsv)
ACR_PASSWORD=$(az acr credential show --name "$ACR_NAME" --query "passwords[0].value" --output tsv)
log "ACR login server: $ACR_LOGIN_SERVER"

# =============================================================================
# STEP 3 — Build and push the CVAT audio image to ACR
# =============================================================================
log "Building CVAT audio image and pushing to ACR..."
log "(This uses ACR's build service — no local Docker required)"

# We build directly in ACR from the CVAT fork root directory.
# Make sure you're running this from your CVAT fork root.
# The Dockerfile.audio extends the official CVAT server image with ffmpeg.

az acr build \
    --registry "$ACR_NAME" \
    --image "cvat-server-audio:latest" \
    --file "dockerfile.audio" \
    . \
    --output none

ok "Image built and pushed: $ACR_LOGIN_SERVER/cvat-server-audio:latest"

# =============================================================================
# STEP 4 — Azure Database for PostgreSQL Flexible Server
# =============================================================================
log "Creating managed PostgreSQL server: $PG_SERVER_NAME"
log "(This takes 3–5 minutes...)"

az postgres flexible-server create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$PG_SERVER_NAME" \
    --location "$LOCATION" \
    --admin-user "$PG_ADMIN_USER" \
    --admin-password "$PG_ADMIN_PASSWORD" \
    --sku-name "Standard_B1ms" \
    --tier "Burstable" \
    --storage-size 32 \
    --version "14" \
    --database-name "$PG_DB_NAME" \
    --public-access "0.0.0.0" \
    --output none

ok "PostgreSQL server created"

# Get the PostgreSQL hostname
PG_HOST=$(az postgres flexible-server show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$PG_SERVER_NAME" \
    --query "fullyQualifiedDomainName" \
    --output tsv)
log "PostgreSQL host: $PG_HOST"

# =============================================================================
# STEP 5 — Azure Blob Storage for videos
# =============================================================================
log "Creating storage account: $STORAGE_ACCOUNT"

az storage account create \
    --name "$STORAGE_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --sku Standard_LRS \
    --kind StorageV2 \
    --output none

# Get the storage connection string
STORAGE_CONNECTION_STRING=$(az storage account show-connection-string \
    --name "$STORAGE_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --query connectionString \
    --output tsv)

# Create a container (bucket) for CVAT data
az storage container create \
    --name "cvat-data" \
    --connection-string "$STORAGE_CONNECTION_STRING" \
    --output none

STORAGE_KEY=$(az storage account keys list \
    --account-name "$STORAGE_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --query "[0].value" \
    --output tsv)

ok "Storage account created"

# =============================================================================
# STEP 6 — Redis (needed by CVAT for task queuing)
# We use a lightweight Azure Container Instance just for Redis
# =============================================================================
log "Deploying Redis container..."

az container create \
    --resource-group "$RESOURCE_GROUP" \
    --name "cvat-redis" \
    --image "redis:7-alpine" \
    --cpu 0.5 \
    --memory 0.5 \
    --restart-policy Always \
    --ports 6379 \
    --output none

REDIS_IP=$(az container show \
    --resource-group "$RESOURCE_GROUP" \
    --name "cvat-redis" \
    --query "ipAddress.ip" \
    --output tsv)

ok "Redis running at $REDIS_IP:6379"

# =============================================================================
# STEP 7 — Deploy CVAT Container
# =============================================================================
log "Deploying CVAT container..."

az container create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$CONTAINER_NAME" \
    --image "$ACR_LOGIN_SERVER/cvat-server-audio:latest" \
    --registry-login-server "$ACR_LOGIN_SERVER" \
    --registry-username "$ACR_NAME" \
    --registry-password "$ACR_PASSWORD" \
    --cpu 2 \
    --memory 4 \
    --restart-policy Always \
    --ports 8080 \
    --dns-name-label "$DNS_LABEL" \
    --location "$LOCATION" \
    --environment-variables \
        CVAT_POSTGRES_HOST="$PG_HOST" \
        CVAT_POSTGRES_DBNAME="$PG_DB_NAME" \
        CVAT_POSTGRES_USER="$PG_ADMIN_USER" \
        CVAT_POSTGRES_PORT="5432" \
        CVAT_REDIS_HOST="$REDIS_IP" \
        CVAT_REDIS_PORT="6379" \
        DJANGO_LOG_SERVER_HOST="localhost" \
        CVAT_DEPLOYMENT_TYPE="none" \
        CVAT_HOST="$DNS_LABEL.$LOCATION.azurecontainer.io" \
    --secure-environment-variables \
        CVAT_POSTGRES_PASSWORD="$PG_ADMIN_PASSWORD" \
        CVAT_SECRET_KEY="$(openssl rand -hex 32)" \
    --output none

ok "CVAT container deployed"

# =============================================================================
# STEP 8 — Create superuser in CVAT
# =============================================================================
log "Waiting 30 seconds for CVAT to initialize..."
sleep 30

log "Creating CVAT superuser (demo / $CVAT_SUPERUSER_PASSWORD)..."
az container exec \
    --resource-group "$RESOURCE_GROUP" \
    --name "$CONTAINER_NAME" \
    --exec-command \
    "python manage.py createsuperuser --username demo --email demo@example.com --no-input" \
    2>/dev/null || warn "Superuser may already exist — continuing"

# Set password separately (createsuperuser --no-input creates with unusable password)
az container exec \
    --resource-group "$RESOURCE_GROUP" \
    --name "$CONTAINER_NAME" \
    --exec-command \
    "python manage.py shell -c \"from django.contrib.auth import get_user_model; U=get_user_model(); u=U.objects.get(username='demo'); u.set_password('$CVAT_SUPERUSER_PASSWORD'); u.save()\"" \
    2>/dev/null || warn "Could not set password via exec — set it manually in the container"

# =============================================================================
# STEP 9 — Done! Print summary
# =============================================================================
FQDN="$DNS_LABEL.$LOCATION.azurecontainer.io"

echo ""
echo "============================================================"
ok "DEPLOYMENT COMPLETE"
echo "============================================================"
echo ""
echo "  Live URL:   http://$FQDN:8080"
echo "  Username:   demo"
echo "  Password:   $CVAT_SUPERUSER_PASSWORD"
echo ""
echo "  Resource Group:   $RESOURCE_GROUP"
echo "  PostgreSQL:       $PG_HOST"
echo "  Storage Account:  $STORAGE_ACCOUNT"
echo "  Container:        $CONTAINER_NAME"
echo ""
echo "  To stream logs:"
echo "    az container logs --resource-group $RESOURCE_GROUP --name $CONTAINER_NAME --follow"
echo ""
echo "  To tear down everything (saves Azure credits):"
echo "    ./teardown.sh"
echo "============================================================"
