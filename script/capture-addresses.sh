#!/usr/bin/env bash
# =============================================================================
# AgiArena Post-Deployment Address Capture Script
# =============================================================================
# Purpose: Parse forge script output and save deployed addresses to JSON
# Usage:   ./script/capture-addresses.sh
# Run from: contracts/ directory, after running forge script
# =============================================================================

set -euo pipefail

# Chain ID: defaults to Base mainnet (8453), can be overridden via argument or env var
CHAIN_ID="${1:-${CHAIN_ID:-8453}}"

# Path to forge broadcast output
BROADCAST_FILE="broadcast/Deploy.s.sol/${CHAIN_ID}/run-latest.json"

echo "=== AgiArena Address Capture ==="
echo "Chain ID: $CHAIN_ID"
echo "Looking for broadcast file: $BROADCAST_FILE"

if [ ! -f "$BROADCAST_FILE" ]; then
    echo "❌ ERROR: Broadcast file not found at $BROADCAST_FILE"
    echo ""
    # Try to find any broadcast files
    echo "Available broadcast directories:"
    ls -la broadcast/Deploy.s.sol/ 2>/dev/null || echo "  (none found)"
    echo ""
    echo "Make sure you ran the deployment script first:"
    echo "  forge script script/Deploy.s.sol --rpc-url \$BASE_RPC_URL --broadcast"
    echo ""
    echo "If deploying to a different chain, specify chain ID:"
    echo "  ./script/capture-addresses.sh <chain_id>"
    echo "  Example: ./script/capture-addresses.sh 31337  # localhost"
    echo ""
    exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "❌ ERROR: jq is required but not installed"
    echo "Install with: brew install jq (macOS) or apt install jq (Linux)"
    exit 1
fi

# Extract AgiArenaCore address from broadcast JSON
CORE_ADDRESS=$(jq -r '.transactions[] | select(.contractName == "AgiArenaCore") | .contractAddress' "$BROADCAST_FILE")

if [ -z "$CORE_ADDRESS" ] || [ "$CORE_ADDRESS" == "null" ]; then
    echo "❌ ERROR: Could not find AgiArenaCore deployment in broadcast file"
    echo ""
    echo "Contents of broadcast file:"
    jq '.transactions[] | {contractName, contractAddress}' "$BROADCAST_FILE"
    exit 1
fi

# Extract ResolutionDAO address from broadcast JSON (first occurrence only)
RESOLUTION_DAO_ADDRESS=$(jq -r '[.transactions[] | select(.contractName == "ResolutionDAO") | .contractAddress][0] // empty' "$BROADCAST_FILE")

if [ -z "$RESOLUTION_DAO_ADDRESS" ] || [ "$RESOLUTION_DAO_ADDRESS" == "null" ]; then
    echo "⚠️  WARNING: Could not find ResolutionDAO deployment in broadcast file"
    echo "   This is expected if ResolutionDAO was not deployed in this run"
    RESOLUTION_DAO_ADDRESS=""
fi

# Get deployment timestamp
DEPLOY_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Write to deployed-contracts.json in project root
OUTPUT_FILE="../deployed-contracts.json"

# Build JSON with optional ResolutionDAO
if [ -n "$RESOLUTION_DAO_ADDRESS" ]; then
cat > "$OUTPUT_FILE" << EOF
{
  "network": "base-mainnet",
  "chainId": ${CHAIN_ID},
  "deployedAt": "${DEPLOY_TIMESTAMP}",
  "contracts": {
    "AgiArenaCore": "${CORE_ADDRESS}",
    "ResolutionDAO": "${RESOLUTION_DAO_ADDRESS}"
  }
}
EOF
else
cat > "$OUTPUT_FILE" << EOF
{
  "network": "base-mainnet",
  "chainId": ${CHAIN_ID},
  "deployedAt": "${DEPLOY_TIMESTAMP}",
  "contracts": {
    "AgiArenaCore": "${CORE_ADDRESS}"
  }
}
EOF
fi

echo "✅ Deployment addresses captured!"
echo ""
echo "Contract Addresses:"
echo "  AgiArenaCore: $CORE_ADDRESS"
if [ -n "$RESOLUTION_DAO_ADDRESS" ]; then
    echo "  ResolutionDAO: $RESOLUTION_DAO_ADDRESS"
fi
echo ""
echo "Saved to: $OUTPUT_FILE"
echo ""
echo "=== Next Steps ==="
echo "1. Update root .env with:"
echo "   CONTRACT_ADDRESS=$CORE_ADDRESS"
if [ -n "$RESOLUTION_DAO_ADDRESS" ]; then
    echo "   RESOLUTION_DAO_ADDRESS=$RESOLUTION_DAO_ADDRESS"
fi
echo ""
echo "2. Run sync-env.sh to propagate to all components:"
echo "   cd .. && ./sync-env.sh"
echo ""
echo "3. Verify contracts on BaseScan:"
echo "   https://basescan.org/address/$CORE_ADDRESS"
if [ -n "$RESOLUTION_DAO_ADDRESS" ]; then
    echo "   https://basescan.org/address/$RESOLUTION_DAO_ADDRESS"
fi
