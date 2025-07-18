#!/bin/bash

# OmniSynth Contract Initialization Scripts
# Make sure you have the Aptos CLI installed and configured

# Configuration
NETWORK="testnet"  # Change to "mainnet" for production
PROFILE="default"  # Your Aptos CLI profile name
PACKAGE_DIR="./Move.toml"    # Directory containing Move.toml

# Contract addresses from Move.toml
OWNER_ADDRESS="0x7810503269f5f18dd5607bd640d65679b7700ae1957a22b94bce32eb2408164c"
DATA_FEEDS_ADDRESS="0xf1099f135ddddad1c065203431be328a408b0ca452ada70374ce26bd2b32fdd3"
PLATFORM_ADDRESS="0x516e771e1b4a903afe74c27d057c65849ecc1383782f6642d7ff21425f4f9c99"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== OmniSynth Contract Initialization ===${NC}"
echo ""

# Function to check if command succeeded
check_status() {
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ $1${NC}"
    else
        echo -e "${RED}✗ $1 failed${NC}"
        exit 1
    fi
}

# Function to wait for user confirmation
wait_for_confirmation() {
    echo -e "${YELLOW}Press Enter to continue...${NC}"
    read
}


echo -e "${YELLOW}Step 3: Initialize Pool Contract${NC}"
echo "Initializing liquidity pool..."

# Generate a unique seed for the pool resource account
POOL_SEED=9a43f3aaec5e77b41893827dbad32158
# echo "Using seed: $POOL_SEED"

# aptos move run \
#     --profile $PROFILE \
#     --function-id ${OWNER_ADDRESS}::pool_v1::initialize \
#     --args "hex:$POOL_SEED"
# check_status "Pool initialization"

# Get the pool resource account address
# echo "Getting pool resource account address..."
# POOL_RESOURCE_ACCOUNT=$(aptos account derive-resource-account-address --address $OWNER_ADDRESS --seed "$POOL_SEED" | grep "Resource Account Address" | cut -d' ' -f4)
# echo "Pool resource account address: $POOL_RESOURCE_ACCOUNT"
# wait_for_confirmation

POOL_RESOURCE_ACCOUNT=0x2145439220403320ba1272319c6002746f4e621eefe3197a73106232526f7cb6

# echo -e "${YELLOW}Step 4: Initialize Trading Engine${NC}"
# echo "Initializing trading engine..."

# Generate a unique seed for the trading engine resource account
# TRADING_SEED=$(date +%s | sha256sum | cut -c1-32)

TRADING_SEED=439537bd18ee592c8a92c353107d6358


# aptos move run \
#   --profile $PROFILE \
#   --function-id ${OWNER_ADDRESS}::trading_engine_v1::initialize \
#   --args "address:$POOL_RESOURCE_ACCOUNT" "hex:$TRADING_SEED"

# check_status "Trading engine initialization"

# Get the trading engine resource account address
# echo "Getting trading engine resource account address..."
# TRADING_RESOURCE_ACCOUNT=$(aptos account derive-resource-account-address --profile $PROFILE --seed "0x$TRADING_SEED" --address $OWNER_ADDRESS | grep "Resource Account Address" | cut -d' ' -f4)
# echo "Trading engine resource account address: $TRADING_RESOURCE_ACCOUNT"
# wait_for_confirmation

TRADING_RESOURCE_ACCOUNT=ccfa5d32f3bdd7bf44582b2d140f2d18ad015b36d1c6323f16880da303accf66

echo -e "${YELLOW}Step 5: Add supported markets to pool${NC}"
echo "Adding BTC/USD market to pool..."
aptos move run \
    --profile $PROFILE \
    --function-id ${OWNER_ADDRESS}::pool_v1::add_market \
    --args "address:$POOL_RESOURCE_ACCOUNT" "string:BTC/USD"
check_status "BTC/USD market added to pool"

echo "Adding ETH/USD market to pool..."
aptos move run \
    --profile $PROFILE \
    --function-id ${OWNER_ADDRESS}::pool_v1::add_market \
    --args "address:$POOL_RESOURCE_ACCOUNT" "string:ETH/USD"
check_status "ETH/USD market added to pool"

echo "Adding APT/USD market to pool..."
aptos move run \
    --profile $PROFILE \
    --function-id ${OWNER_ADDRESS}::pool_v1::add_market \
    --args "address:$POOL_RESOURCE_ACCOUNT" "string:APT/USD"
check_status "APT/USD market added to pool"

echo -e "${YELLOW}Step 6: Add supported markets to trading engine${NC}"
echo "Adding BTC/USD market to trading engine..."
# You'll need to replace these feed IDs with actual Chainlink feed IDs
BTC_FEED_ID="0x01a0b4d920000332000000000000000000000000000000000000000000000000"
aptos move run \
    --profile $PROFILE \
    --function-id ${OWNER_ADDRESS}::trading_engine_v1::add_market \
    --args "address:$TRADING_RESOURCE_ACCOUNT" "string:BTC/USD" "hex:$BTC_FEED_ID" "u64:50"
check_status "BTC/USD market added to trading engine"

echo "Adding ETH/USD market to trading engine..."
ETH_FEED_ID="0x01d585327c000332000000000000000000000000000000000000000000000000"
aptos move run \
    --profile $PROFILE \
    --function-id ${OWNER_ADDRESS}::trading_engine_v1::add_market \
    --args "address:$TRADING_RESOURCE_ACCOUNT" "string:ETH/USD" "hex:$ETH_FEED_ID" "u64:50"
check_status "ETH/USD market added to trading engine"

echo "Adding APT/USD market to trading engine..."
APT_FEED_ID="0x011e22d6bf000332000000000000000000000000000000000000000000000000"
aptos move run \
    --profile $PROFILE \
    --function-id ${OWNER_ADDRESS}::trading_engine_v1::add_market \
    --args "address:$TRADING_RESOURCE_ACCOUNT" "string:APT/USD" "hex:$APT_FEED_ID" "u64:30"
check_status "APT/USD market added to trading engine"

echo ""
echo -e "${GREEN}=== Initialization Complete ===${NC}"
echo ""
echo -e "${GREEN}Contract Addresses:${NC}"
echo "Owner/Publisher: $OWNER_ADDRESS"
echo "Pool Resource Account: $POOL_RESOURCE_ACCOUNT"
echo "Trading Engine Resource Account: $TRADING_RESOURCE_ACCOUNT"
echo ""
echo -e "${GREEN}Supported Markets:${NC}"
echo "- BTC/USD (Max leverage: 50x)"
echo "- ETH/USD (Max leverage: 50x)"
echo "- APT/USD (Max leverage: 30x)"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Save the resource account addresses for your frontend"
echo "2. Fund the contracts with initial liquidity"
echo "3. Test the trading functions"
echo "4. Update price feeds regularly"
echo ""
echo -e "${GREEN}=== Setup Complete ===${NC}"