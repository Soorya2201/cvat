#!/usr/bin/env bash
# =============================================================================
# FILE: teardown.sh
#
# Deletes ALL Azure resources created by deploy.sh.
# Run this when you want to stop the demo and save your student credits.
#
# WARNING: This permanently deletes the resource group and everything in it.
# =============================================================================

set -euo pipefail

RESOURCE_GROUP="cvat-everyday-respect-rg"

echo "WARNING: This will delete the resource group '$RESOURCE_GROUP'"
echo "and ALL resources inside it (containers, database, storage)."
echo ""
read -p "Type 'yes' to confirm: " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Cancelled."
    exit 0
fi

echo "Deleting resource group $RESOURCE_GROUP..."
az group delete \
    --name "$RESOURCE_GROUP" \
    --yes \
    --no-wait

echo "Deletion started (runs in background on Azure)."
echo "All resources will be removed in ~5 minutes."
