#!/bin/bash

# ==============================================================================
# APTOS OMNISYNTH CONTRACT INITIALIZATION AND INTERACTION SCRIPTS
# ==============================================================================

# Configuration
NETWORK="testnet"  # Change to "mainnet" for production
PROFILE="default"  # Your Aptos CLI profile
MODULE_ADDRESS="0x7810503269f5f18dd5607bd640d65679b7700ae1957a22b94bce32eb2408164c" # Replace with your module address
USDC_ADDRESS="0x69091fbab5f7d635ee7ac5098cf0c1efbe31d68fec0f2cd565e8d168daf52832"  # Testnet USDC address
POOL_ADDRESS="0x7810503269f5f18dd5607bd640d65679b7700ae1957a22b94bce32eb2408164c" # Will be set after pool initialization
TRADING_ENGINE_ADDRESS="0x7810503269f5f18dd5607bd640d65679b7700ae1957a22b94bce32eb2408164c"  # Will be set after trading engine initialization

# ==============================================================================
# UTILITY FUNCTIONS
# ==============================================================================

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

check_command() {
    if ! command -v aptos &> /dev/null; then
        echo "Error: Aptos CLI not found. Please install it first."
        exit 1
    fi
}

# ==============================================================================
# INITIALIZATION SCRIPTS
# ==============================================================================

# # Initialize Pool Contract
# init_pool() {
#     log "Initializing Pool Contract..."
    
#     aptos move run \
#         --function-id "${MODULE_ADDRESS}::pool_v3::initialize" \
#         --profile $PROFILE 
    
#     if [ $? -eq 0 ]; then
#         log "Pool contract initialized successfully"
#         # Get the pool address (same as signer address for this contract)
#         POOL_ADDRESS=$(aptos account list --profile $PROFILE --network $NETWORK | grep "account" | awk '{print $2}' | tr -d '"')
#         echo "POOL_ADDRESS=$POOL_ADDRESS" >> .env
#         log "Pool Address: $POOL_ADDRESS"
#     else
#         log "Failed to initialize pool contract"
#         exit 1
#     fi
# }

# Set USDC Metadata for Pool
set_pool_usdc_metadata() {
    log "Setting USDC metadata for pool..."
    
    aptos move run \
        --function-id "${MODULE_ADDRESS}::pool_v3::set_usdc_metadata" \
        --args address:$USDC_ADDRESS \
        --profile $PROFILE 
    
    if [ $? -eq 0 ]; then
        log "USDC metadata set successfully"
    else
        log "Failed to set USDC metadata"
        exit 1
    fi
}

# Initialize Trading Engine
init_trading_engine() {
    log "Initializing Trading Engine..."
    
    aptos move run \
        --function-id "${MODULE_ADDRESS}::trading_engine_v3::initialize" \
        --args address:$MODULE_ADDRESS address:$USDC_ADDRESS \
        --profile $PROFILE 
    
    if [ $? -eq 0 ]; then
        log "Trading engine initialized successfully"
        TRADING_ENGINE_ADDRESS=$(aptos account list --profile $PROFILE --network $NETWORK | grep "account" | awk '{print $2}' | tr -d '"')
        echo "TRADING_ENGINE_ADDRESS=$TRADING_ENGINE_ADDRESS" >> .env
        log "Trading Engine Address: $TRADING_ENGINE_ADDRESS"
    else
        log "Failed to initialize trading engine"
        exit 1
    fi
}

# ==============================================================================
# POOL MANAGEMENT FUNCTIONS
# ==============================================================================

# Add supported markets to pool
add_pool_markets() {
    log "Adding markets to pool..."
    
    markets=("BTC/USD" "ETH/USD" "APT/USD" "SOL/USD")
    
    for market in "${markets[@]}"; do
        log "Adding market: $market"
        aptos move run \
            --function-id "${MODULE_ADDRESS}::pool_v3::add_market" \
            --args string:$market \
            --profile $PROFILE 
        
        if [ $? -eq 0 ]; then
            log "Market $market added successfully"
        else
            log "Failed to add market $market"
        fi
    done
}

# Add liquidity to pool
add_liquidity() {
    local amount=${1:-1000000}  # Default: 1 USDC (6 decimals)
    
    log "Adding liquidity: $amount USDC"
    
    aptos move run \
        --function-id "${MODULE_ADDRESS}::pool_v3::add_liquidity" \
        --args address:$MODULE_ADDRESS u64:$amount \
        --profile $PROFILE 
    
    if [ $? -eq 0 ]; then
        log "Liquidity added successfully"
    else
        log "Failed to add liquidity"
    fi
}

# Remove liquidity from pool
remove_liquidity() {
    local shares=${1:-1000000}  # Default: 1M shares
    
    log "Removing liquidity: $shares shares"
    
    aptos move run \
        --function-id "${MODULE_ADDRESS}::pool_v3::remove_liquidity" \
        --args address:$MODULE_ADDRESS u64:$shares \
        --profile $PROFILE 
    
    if [ $? -eq 0 ]; then
        log "Liquidity removed successfully"
    else
        log "Failed to remove liquidity"
    fi
}

# Process withdrawal (pool owner only)
process_withdrawal() {
    local recipient=${1}
    local amount=${2}
    
    if [ -z "$recipient" ] || [ -z "$amount" ]; then
        log "Usage: process_withdrawal <recipient_address> <amount>"
        return 1
    fi
    
    log "Processing withdrawal for $recipient: $amount USDC"
    
    aptos move run \
        --function-id "${MODULE_ADDRESS}::pool_v3::process_withdrawal" \
        --args address:$recipient u64:$amount \
        --profile $PROFILE 
    
    if [ $? -eq 0 ]; then
        log "Withdrawal processed successfully"
    else
        log "Failed to process withdrawal"
    fi
}


allocate_liquidity() {
    local amount=${1:-3000000}  # Default: 3 USDC (6 decimals)
      local market=${2:-"BTC/USD"}
      local is_long=${3:-true}  # Default: true (long position)
    
    log "Allocating $amount to: $market is_long: $is_long"
    aptos move run \
  --function-id "${MODULE_ADDRESS}::pool_v3::allocate_liquidity_v2" \
  --args address:$POOL_ADDRESS string:$market bool:$is_long u64:$amount \
  --profile default

   
    if [ $? -eq 0 ]; then
        log "Liquidity allocated successfully"
    else
        log "Failed to allocate liquidity"
    fi

}

# ==============================================================================
# TRADING ENGINE FUNCTIONS
# ==============================================================================

# Add markets to trading engine
add_trading_markets() {
    log "Adding markets to trading engine..."

    # Format: MarketName|FeedID|MaxLeverage
    markets=(
        "BTC/USD|01a0b4d920000332000000000000000000000000000000000000000000000000|100"
        "ETH/USD|01d585327c000332000000000000000000000000000000000000000000000000|100"
        "APT/USD|011e22d6bf000332000000000000000000000000000000000000000000000000|100"
    )

    for entry in "${markets[@]}"; do
        IFS='|' read -r market feed_id max_leverage <<< "$entry"

        log "Adding trading market: $market"
        log "  → Feed ID: $feed_id"
        log "  → Max Leverage: $max_leverage"

        aptos move run \
            --function-id "${MODULE_ADDRESS}::trading_engine_v3::add_market" \
            --args address:$MODULE_ADDRESS string:"$market" hex:$feed_id u64:$max_leverage \
            --profile "$PROFILE"

        if [ $? -eq 0 ]; then
            log "✅ Market $market added successfully"
        else
            log "❌ Failed to add market $market"
        fi
    done
}


# Deposit collateral
deposit_collateral() {
    local amount=${1:-1000000}  # Default: 1 USDC (6 decimals)
    
    log "Depositing collateral: $amount USDC"
    
    aptos move run \
        --function-id "${MODULE_ADDRESS}::trading_engine_v3::deposit_collateral" \
        --args address:$MODULE_ADDRESS u64:$amount \
        --profile $PROFILE 
    
    if [ $? -eq 0 ]; then
        log "Collateral deposited successfully"
    else
        log "Failed to deposit collateral"
    fi
}

# Withdraw collateral
withdraw_collateral() {
    local amount=${1:-500000}  # Default: 0.5 USDC (6 decimals)
    
    log "Withdrawing collateral: $amount USDC"
    
    aptos move run \
        --function-id "${MODULE_ADDRESS}::trading_engine_v3::withdraw_collateral" \
        --args address:$MODULE_ADDRESS u64:$amount \
        --profile $PROFILE 
    
    if [ $? -eq 0 ]; then
        log "Collateral withdrawn successfully"
    else
        log "Failed to withdraw collateral"
    fi
}

# Update price for a market
update_price() {
    local market=${1:-"BTC/USD"}
    
    log "Updating price for market: $market"
    
    aptos move run \
        --function-id "${MODULE_ADDRESS}::trading_engine_v3::update_price" \
        --args address:$TRADING_ENGINE_ADDRESS string:$market \
        --profile $PROFILE 
    
    if [ $? -eq 0 ]; then
        log "Price updated successfully for $market"
    else
        log "Failed to update price for $market"
    fi
}

# Place a market order
place_market_order() {
    local market=${1:-"BTC/USD"}
    local is_long=${2:-"true"}
    local size=${3:-"1000000"}     # Default: 1 USDC position size
    local leverage=${4:-"10"}      # Default: 10x leverage
    
    log "Placing market order: $market, Long: $is_long, Size: $size, Leverage: $leverage"
    
    aptos move run \
        --function-id "${MODULE_ADDRESS}::trading_engine_v3::place_order" \
        --args address:$TRADING_ENGINE_ADDRESS string:$market bool:$is_long u64:$size u64:0 u64:$leverage bool:true \
        --profile $PROFILE 
    
    if [ $? -eq 0 ]; then
        log "Market order placed successfully"
    else
        log "Failed to place market order"
    fi
}

# Place a limit order
place_limit_order() {
    local market=${1:-"BTC/USD"}
    local is_long=${2:-"true"}
    local size=${3:-"1000000"}     # Default: 1 USDC position size
    local price=${4:-"5000000000000"} # Default: $50,000 (8 decimals)
    local leverage=${5:-"10"}      # Default: 10x leverage
    
    log "Placing limit order: $market, Long: $is_long, Size: $size, Price: $price, Leverage: $leverage"
    
    aptos move run \
        --function-id "${MODULE_ADDRESS}::trading_engine_v3::place_order" \
        --args address:$TRADING_ENGINE_ADDRESS string:$market bool:$is_long u64:$size u64:$price u64:$leverage bool:false \
        --profile $PROFILE 
    
    if [ $? -eq 0 ]; then
        log "Limit order placed successfully"
    else
        log "Failed to place limit order"
    fi
}

# Execute an order
execute_order() {
    local order_id=${1}
    
    if [ -z "$order_id" ]; then
        log "Usage: execute_order <order_id>"
        return 1
    fi
    
    log "Executing order: $order_id"
    
    aptos move run \
        --function-id "${MODULE_ADDRESS}::trading_engine_v3::execute_order" \
        --args address:$TRADING_ENGINE_ADDRESS u64:$order_id \
        --profile $PROFILE 
    
    if [ $? -eq 0 ]; then
        log "Order executed successfully"
    else
        log "Failed to execute order"
    fi
}

# Close a position
close_position() {
    local position_id=${1}
    
    if [ -z "$position_id" ]; then
        log "Usage: close_position <position_id>"
        return 1
    fi
    
    log "Closing position: $position_id"
    
    aptos move run \
        --function-id "${MODULE_ADDRESS}::trading_engine_v3::close_position" \
        --args address:$TRADING_ENGINE_ADDRESS u64:$position_id \
        --profile $PROFILE 
    
    if [ $? -eq 0 ]; then
        log "Position closed successfully"
    else
        log "Failed to close position"
    fi
}

# Liquidate a position
liquidate_position() {
    local position_id=${1}
    
    if [ -z "$position_id" ]; then
        log "Usage: liquidate_position <position_id>"
        return 1
    fi
    
    log "Liquidating position: $position_id"
    
    aptos move run \
        --function-id "${MODULE_ADDRESS}::trading_engine_v3::liquidate_position" \
        --args address:$TRADING_ENGINE_ADDRESS u64:$position_id \
        --profile $PROFILE 
    
    if [ $? -eq 0 ]; then
        log "Position liquidated successfully"
    else
        log "Failed to liquidate position"
    fi
}

# ==============================================================================
# VIEW FUNCTIONS
# ==============================================================================

# Get pool information
get_pool_info() {
    local market=${1:-"BTC/USD"}
    
    log "Getting pool info for market: $market"
    
    aptos move view \
        --function-id "${MODULE_ADDRESS}::pool_v3::get_pool_info" \
        --args address:$POOL_ADDRESS string:$market \
        --profile $PROFILE 
}

# Get total pool value
get_total_pool_value() {
    log "Getting total pool value..."
    
    aptos move view \
        --function-id "${MODULE_ADDRESS}::pool_v3::get_total_pool_value" \
        --args address:$POOL_ADDRESS \
        --profile $PROFILE 
}

# Get insurance fund
get_insurance_fund() {
    log "Getting insurance fund..."
    
    aptos move view \
        --function-id "${MODULE_ADDRESS}::pool_v3::get_insurance_fund" \
        --args address:$POOL_ADDRESS \
        --profile $PROFILE 
}

# Get available collateral
get_available_collateral() {
    # local user_address=${1}
    
    # if [ -z "$user_address" ]; then
    #     user_address=$(aptos account list --profile $PROFILE | grep "account" | awk '{print $2}' | tr -d '"')
    # fi
    
    # log "Getting available collateral for user: $user_address"
    
    aptos move view \
        --function-id "${MODULE_ADDRESS}::trading_engine_v3::get_available_collateral" \
        --args address:$TRADING_ENGINE_ADDRESS address:$MODULE_ADDRESS \
        --profile $PROFILE 
}

# Get position details
get_position() {
    local position_id=${1}
    
    if [ -z "$position_id" ]; then
        log "Usage: get_position <position_id>"
        return 1
    fi
    
    log "Getting position details: $position_id"
    
    aptos move view \
        --function-id "${MODULE_ADDRESS}::trading_engine_v3::get_position" \
        --args address:$TRADING_ENGINE_ADDRESS u64:$position_id \
        --profile $PROFILE 
}

# Get current price
get_current_price() {
    local market=${1:-"BTC/USD"}
    
    log "Getting current price for market: $market"
    
    aptos move view \
        --function-id "${MODULE_ADDRESS}::trading_engine_v3::get_current_price" \
        --args address:$TRADING_ENGINE_ADDRESS string:$market \
        --profile $PROFILE 
}

# Check if position is liquidatable
is_liquidatable() {
    local position_id=${1}
    
    if [ -z "$position_id" ]; then
        log "Usage: is_liquidatable <position_id>"
        return 1
    fi
    
    log "Checking if position is liquidatable: $position_id"
    
    aptos move view \
        --function-id "${MODULE_ADDRESS}::trading_engine_v3::is_liquidatable" \
        --args address:$TRADING_ENGINE_ADDRESS u64:$position_id \
        --profile $PROFILE 
}

# ==============================================================================
# EMERGENCY FUNCTIONS
# ==============================================================================

# Pause trading contract
pause_contract() {
    log "Pausing trading contract..."
    
    aptos move run \
        --function-id "${MODULE_ADDRESS}::trading_engine_v3::pause_contract" \
        --args address:$TRADING_ENGINE_ADDRESS \
        --profile $PROFILE 
    
    if [ $? -eq 0 ]; then
        log "Trading contract paused successfully"
    else
        log "Failed to pause trading contract"
    fi
}

# Unpause trading contract
unpause_contract() {
    log "Unpausing trading contract..."
    
    aptos move run \
        --function-id "${MODULE_ADDRESS}::trading_engine_v3::unpause_contract" \
        --args address:$TRADING_ENGINE_ADDRESS \
        --profile $PROFILE 
    
    if [ $? -eq 0 ]; then
        log "Trading contract unpaused successfully"
    else
        log "Failed to unpause trading contract"
    fi
}

# Emergency withdraw from insurance fund
emergency_withdraw() {
    local amount=${1:-"1000000"}  # Default: 1 USDC
    
    log "Emergency withdrawal: $amount USDC"
    
    aptos move run \
        --function-id "${MODULE_ADDRESS}::pool_v3::emergency_withdraw" \
        --args u64:$amount \
        --profile $PROFILE 
    
    if [ $? -eq 0 ]; then
        log "Emergency withdrawal successful"
    else
        log "Failed to perform emergency withdrawal"
    fi
}

# ==============================================================================
# COMPREHENSIVE SETUP SCRIPT
# ==============================================================================

full_setup() {
    log "Starting full setup..."
    
    check_command
    
    # Load environment variables if .env file exists
    if [ -f ".env" ]; then
        source .env
    fi
    
    # Initialize contracts
    # init_pool
    # set_pool_usdc_metadata
    # init_trading_engine
    
    # # Add markets
    # add_pool_markets
    add_trading_markets
    
    # Add initial liquidity
    # add_liquidity 5000000  # 5 USDC
    
    # # Deposit initial collateral
    # deposit_collateral 1000000  # 1 USDC
    
    log "Full setup completed successfully!"
}

# ==============================================================================
# TESTING SCRIPT
# ==============================================================================

run_tests() {
    log "Running comprehensive tests..."
    
    # # Test price updates
    # update_price "BTC/USD"
    # update_price "ETH/USD"
    
    # # Test trading
    place_market_order "BTC/USD" "true" "1000" "1"  # 2 USDC, 5x leverage, long
    # place_limit_order "ETH/USD" "false" "1500000" "300000000000" "3"  # 1.5 USDC, $3000, 3x leverage, short
    
    # View functions
    # get_pool_info "BTC/USD"
    # get_total_pool_value
    # get_insurance_fund
    # get_available_collateral
    # get_current_price "BTC/USD"
    # get_current_price "ETH/USD"
    # get_current_price "APT/USD"
    # allocate_liquidity "3000000" "BTC/USD" "false"  # Allocate 3 USDC to BTC/USD long position
    
    log "Tests completed!"
}

# ==============================================================================
# MAIN SCRIPT EXECUTION
# ==============================================================================

case "$1" in
    "init")
        full_setup
        ;;
    "test")
        run_tests
        ;;
    "pool-info")
        get_pool_info $2
        ;;
    "add-liquidity")
        add_liquidity $2
        ;;
    "remove-liquidity")
        remove_liquidity $2
        ;;
    "deposit")
        deposit_collateral $2
        ;;
    "withdraw")
        withdraw_collateral $2
        ;;
        "allocate-liquidity")
        allocate_liquidity $2 $3 $4
        ;;
    "market-order")
        place_market_order $2 $3 $4 $5
        ;;
    "limit-order")
        place_limit_order $2 $3 $4 $5 $6
        ;;
    "close-position")
        close_position $2
        ;;
    "liquidate")
        liquidate_position $2
        ;;
    "update-price")
        update_price $2
        ;;
    "pause")
        pause_contract
        ;;
    "unpause")
        unpause_contract
        ;;
    "emergency")
        emergency_withdraw $2
        ;;
    *)
        echo "Usage: $0 {init|test|pool-info|add-liquidity|remove-liquidity|deposit|withdraw|market-order|limit-order|close-position|liquidate|update-price|pause|unpause|emergency}"
        echo ""
        echo "Examples:"
        echo "  $0 init                                    # Full setup"
        echo "  $0 test                                    # Run tests"
        echo "  $0 pool-info BTC/USD                       # Get pool info"
        echo "  $0 add-liquidity 10000000                  # Add 10 USDC liquidity"
        echo "  $0 deposit 5000000                         # Deposit 5 USDC collateral"
        echo "  $0 market-order BTC/USD true 1000000 10    # Market order: BTC/USD long, 1 USDC, 10x"
        echo "  $0 limit-order ETH/USD false 2000000 300000000000 5  # Limit order: ETH/USD short, 2 USDC, $3000, 5x"
        echo "  $0 close-position 1                        # Close position ID 1"
        echo "  $0 update-price BTC/USD                     # Update BTC/USD price"
        exit 1
        ;;
esac