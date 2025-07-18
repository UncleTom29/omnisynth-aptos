module omnisynth::trading_engine_v3 {
    use std::signer;
    use std::string::String;
    use std::vector;
    use aptos_framework::fungible_asset::{Self, Metadata};
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::event;
    use aptos_framework::timestamp;
    use aptos_std::table::{Self, Table};
    use data_feeds::router::get_benchmarks;
    use data_feeds::registry::{Benchmark, get_benchmark_value, get_benchmark_timestamp};
    use omnisynth::pool_v3 as pool_v2;

    // Error codes
    const E_NOT_AUTHORIZED: u64 = 1;
    const E_INSUFFICIENT_COLLATERAL: u64 = 2;
    const E_INVALID_LEVERAGE: u64 = 3;
    const E_POSITION_NOT_FOUND: u64 = 4;
    const E_ORDER_NOT_FOUND: u64 = 5;
    const E_INSUFFICIENT_LIQUIDITY: u64 = 6;
    const E_PRICE_FEED_NOT_FOUND: u64 = 7;
    const E_STALE_PRICE: u64 = 8;
    const E_INVALID_PRICE: u64 = 9;
    const E_TRANSFER_FAILED: u64 = 10;
    const E_CONTRACT_PAUSED: u64 = 11;
    const E_INVALID_MARKET: u64 = 12;
    const E_INSUFFICIENT_BALANCE: u64 = 13;
    const E_INVALID_METADATA: u64 = 14;
    const E_MARKET_ALREADY_EXISTS: u64 = 15;

    // Constants
    const MAX_LEVERAGE: u64 = 100;
 const PRECISION: u64 = 1000000000; // Reduced from 1e18 to 1e9 to prevent overflow
const PRICE_PRECISION: u64 = 100000000; // Keep as 1e8
const LIQUIDATION_THRESHOLD: u64 = 90; // Keep as 90%
    const STALE_THRESHOLD: u64 = 3600; // 1 hour
    const DEFAULT_TRADING_FEE: u64 = 50; // 0.5%
    const USDC_DECIMALS: u64 = 6; // USDC has 6 decimals

    struct Position has store {
        trader: address,
        market: String,
        is_long: bool,
        size: u64,
        entry_price: u64,
        leverage: u64,
        collateral: u64,
        liquidation_price: u64,
        timestamp: u64,
        is_active: bool,
    }

    struct Order has store {
        id: u64,
        trader: address,
        market: String,
        is_long: bool,
        size: u64,
        price: u64,
        leverage: u64,
        collateral: u64,
        timestamp: u64,
        is_active: bool,
        is_market_order: bool,
    }

    struct PriceData has store, drop {
        price: u256,
        timestamp: u256,
    }

    struct MarketConfig has store {
        feed_id: vector<u8>,
        is_active: bool,
        max_leverage: u64,
    }

    struct TradingState has key {
        positions: Table<u64, Position>,
        orders: Table<u64, Order>,
        user_positions: Table<address, vector<u64>>,
        user_orders: Table<address, vector<u64>>,
        user_collateral: Table<address, u64>,
        market_configs: Table<String, MarketConfig>,
        price_data: Table<String, PriceData>,
        supported_markets: vector<String>, // Track all markets
        next_position_id: u64,
        next_order_id: u64,
        trading_fee: u64,
        is_paused: bool,
        owner: address,
        pool_address: address,
        usdc_metadata: Object<Metadata>,
    }

    // Events
    #[event]
    struct CollateralDepositedEvent has drop, store {
        user: address,
        amount: u64,
    }

    #[event]
    struct CollateralWithdrawnEvent has drop, store {
        user: address,
        amount: u64,
    }

    #[event]
    struct OrderPlacedEvent has drop, store {
        order_id: u64,
        trader: address,
        market: String,
        is_long: bool,
        size: u64,
        price: u64,
    }

    #[event]
    struct OrderExecutedEvent has drop, store {
        order_id: u64,
        position_id: u64,
        execution_price: u64,
    }

    #[event]
    struct PositionClosedEvent has drop, store {
        position_id: u64,
        trader: address,
        pnl: u64,
        is_profit: bool,
    }

    #[event]
    struct PositionLiquidatedEvent has drop, store {
        position_id: u64,
        trader: address,
        liquidation_price: u64,
    }

    #[event]
    struct MarketAddedEvent has drop, store {
        market: String,
        feed_id: vector<u8>,
    }

    public entry fun initialize(account: &signer, pool_address: address, usdc_metadata_address: address) {
        let account_addr = signer::address_of(account);
        let usdc_metadata = object::address_to_object<Metadata>(usdc_metadata_address);
        
        let trading_state = TradingState {
            positions: table::new(),
            orders: table::new(),
            user_positions: table::new(),
            user_orders: table::new(),
            user_collateral: table::new(),
            market_configs: table::new(),
            price_data: table::new(),
            supported_markets: vector::empty(),
            next_position_id: 1,
            next_order_id: 1,
            trading_fee: DEFAULT_TRADING_FEE,
            is_paused: false,
            owner: account_addr,
            pool_address,
            usdc_metadata,
        };
        move_to(account, trading_state);
    }

    public entry fun add_market(
        account: &signer,
        trading_engine_addr: address,
        market: String,
        feed_id: vector<u8>,
        max_leverage: u64
    ) acquires TradingState {
        let account_addr = signer::address_of(account);
        let trading_state = borrow_global_mut<TradingState>(trading_engine_addr);
        assert!(account_addr == trading_state.owner, E_NOT_AUTHORIZED);
        assert!(!trading_state.is_paused, E_CONTRACT_PAUSED);
        assert!(max_leverage <= MAX_LEVERAGE, E_INVALID_LEVERAGE);
        assert!(!table::contains(&trading_state.market_configs, market), E_MARKET_ALREADY_EXISTS);

        let market_config = MarketConfig {
            feed_id: feed_id,
            is_active: true,
            max_leverage,
        };

        table::add(&mut trading_state.market_configs, market, market_config);
        vector::push_back(&mut trading_state.supported_markets, market);
        
        event::emit(MarketAddedEvent { market, feed_id });
    }

    public entry fun deposit_collateral(account: &signer, trading_engine_addr: address, amount: u64) acquires TradingState {
        assert!(amount > 0, E_INSUFFICIENT_COLLATERAL);
        
        let account_addr = signer::address_of(account);
        let trading_state = borrow_global_mut<TradingState>(trading_engine_addr);
        assert!(!trading_state.is_paused, E_CONTRACT_PAUSED);

        // Check user's USDC balance
        let user_balance = primary_fungible_store::balance(account_addr, trading_state.usdc_metadata);
        assert!(user_balance >= amount, E_INSUFFICIENT_BALANCE);

        // Transfer USDC from user to trading engine
        primary_fungible_store::transfer(account, trading_state.usdc_metadata, trading_engine_addr, amount);

        // Update user collateral
        if (!table::contains(&trading_state.user_collateral, account_addr)) {
            table::add(&mut trading_state.user_collateral, account_addr, 0);
        };

        let current_collateral = table::borrow_mut(&mut trading_state.user_collateral, account_addr);
        *current_collateral = *current_collateral + amount;

        event::emit(CollateralDepositedEvent { user: account_addr, amount });
    }

    public entry fun withdraw_collateral(account: &signer, trading_engine_addr: address, amount: u64) acquires TradingState {
        assert!(amount > 0, E_INSUFFICIENT_COLLATERAL);
        
        let account_addr = signer::address_of(account);
        let trading_state = borrow_global_mut<TradingState>(trading_engine_addr);
        assert!(!trading_state.is_paused, E_CONTRACT_PAUSED);
        assert!(account_addr == trading_state.owner, E_NOT_AUTHORIZED); // Only owner can withdraw

        assert!(table::contains(&trading_state.user_collateral, account_addr), E_INSUFFICIENT_COLLATERAL);
        
        let available_collateral = get_available_collateral_internal(trading_state, account_addr);
        assert!(available_collateral >= amount, E_INSUFFICIENT_COLLATERAL);

        let current_collateral = table::borrow_mut(&mut trading_state.user_collateral, account_addr);
        *current_collateral = *current_collateral - amount;

        // Transfer USDC back to user (contract owner must have sufficient balance)
        primary_fungible_store::transfer(account, trading_state.usdc_metadata, account_addr, amount);

        event::emit(CollateralWithdrawnEvent { user: account_addr, amount });
    }

    public entry fun update_price(account: &signer, trading_engine_addr: address, market: String) acquires TradingState {
        let trading_state = borrow_global_mut<TradingState>(trading_engine_addr);
        assert!(table::contains(&trading_state.market_configs, market), E_PRICE_FEED_NOT_FOUND);

        let market_config = table::borrow(&trading_state.market_configs, market);
        let feed_id = market_config.feed_id;

        // Fetch price from oracle
        let feed_ids = vector[feed_id];
        let billing_data = vector[];
        let benchmarks: vector<Benchmark> = get_benchmarks(account, feed_ids, billing_data);
        let benchmark = vector::pop_back(&mut benchmarks);
        let price: u256 = get_benchmark_value(&benchmark);
        let timestamp: u256 = get_benchmark_timestamp(&benchmark);

        // Validate price
        assert!(price > 0, E_INVALID_PRICE);
        let current_time = (timestamp::now_seconds() as u256);
        assert!(current_time - timestamp <= (STALE_THRESHOLD as u256), E_STALE_PRICE);

        // Store price data
        let price_data = PriceData { price, timestamp };
        if (table::contains(&trading_state.price_data, market)) {
            let existing_data = table::borrow_mut(&mut trading_state.price_data, market);
            *existing_data = price_data;
        } else {
            table::add(&mut trading_state.price_data, market, price_data);
        };
    }

 public entry fun place_order(
    account: &signer,
    trading_engine_addr: address,
    market: String,
    is_long: bool,
    size: u64,
    price: u64,
    leverage: u64,
    is_market_order: bool
) acquires TradingState {
    let account_addr = signer::address_of(account);
    let trading_state = borrow_global_mut<TradingState>(trading_engine_addr);
    assert!(!trading_state.is_paused, E_CONTRACT_PAUSED);
    assert!(table::contains(&trading_state.market_configs, market), E_INVALID_MARKET);
    assert!(leverage > 0 && leverage <= MAX_LEVERAGE, E_INVALID_LEVERAGE);
    assert!(size > 0, E_INSUFFICIENT_COLLATERAL);

    let market_config = table::borrow(&trading_state.market_configs, market);
    assert!(market_config.is_active, E_INVALID_MARKET);
    assert!(leverage <= market_config.max_leverage, E_INVALID_LEVERAGE);

    // Safe division to prevent overflow
    let required_collateral = size / leverage;
    let available_collateral = get_available_collateral_internal(trading_state, account_addr);
    assert!(available_collateral >= required_collateral, E_INSUFFICIENT_COLLATERAL);

    // Check liquidity availability
    assert!(check_liquidity_available(trading_state.pool_address, market, is_long, size), E_INSUFFICIENT_LIQUIDITY);

        let order_id = trading_state.next_order_id;
        trading_state.next_order_id = trading_state.next_order_id + 1;

        let order = Order {
            id: order_id,
            trader: account_addr,
            market,
            is_long,
            size,
            price,
            leverage,
            collateral: required_collateral,
            timestamp: timestamp::now_seconds(),
            is_active: true,
            is_market_order,
        };

        table::add(&mut trading_state.orders, order_id, order);

        // Add to user orders
        if (!table::contains(&trading_state.user_orders, account_addr)) {
            table::add(&mut trading_state.user_orders, account_addr, vector::empty());
        };
        let user_orders = table::borrow_mut(&mut trading_state.user_orders, account_addr);
        vector::push_back(user_orders, order_id);

        event::emit(OrderPlacedEvent {
            order_id,
            trader: account_addr,
            market,
            is_long,
            size,
            price,
        });

        // Execute immediately if market order
        if (is_market_order) {
            execute_order_internal(trading_state, order_id);
        };
    }

    public entry fun execute_order(account: &signer, trading_engine_addr: address, order_id: u64) acquires TradingState {
        let trading_state = borrow_global_mut<TradingState>(trading_engine_addr);
        execute_order_internal(trading_state, order_id);
    }

    fun execute_order_internal(trading_state: &mut TradingState, order_id: u64) {
    assert!(table::contains(&trading_state.orders, order_id), E_ORDER_NOT_FOUND);
    let order = table::borrow_mut(&mut trading_state.orders, order_id);
    assert!(order.is_active, E_ORDER_NOT_FOUND);

    // Check if price data exists
    assert!(table::contains(&trading_state.price_data, order.market), E_PRICE_FEED_NOT_FOUND);
    let price_data = table::borrow(&trading_state.price_data, order.market);
    
    // Properly scale the price from u256 to u64
    let scaled_price = price_data.price / 10_000_000_000; // Scale from 1e18 to 1e8
    let current_price = if (scaled_price > (18446744073709551615u256)) {
        18446744073709551615u64
    } else {
        scaled_price as u64
    };

    // Check price conditions for limit orders
    if (!order.is_market_order) {
        if (order.is_long && current_price > order.price) return;
        if (!order.is_long && current_price < order.price) return;
    };

    // Check liquidity availability
    if (!check_liquidity_available(trading_state.pool_address, order.market, order.is_long, order.size)) {
        return
    };

    // Allocate liquidity
    pool_v2::allocate_liquidity_v2(trading_state.pool_address, order.market, order.is_long, order.size);

    let execution_price = if (order.is_market_order) current_price else order.price;
    let position_id = trading_state.next_position_id;
    trading_state.next_position_id = trading_state.next_position_id + 1;

    let liquidation_price = calculate_liquidation_price(execution_price, order.leverage, order.is_long);

    let position = Position {
        trader: order.trader,
        market: order.market,
        is_long: order.is_long,
        size: order.size,
        entry_price: execution_price,
        leverage: order.leverage,
        collateral: order.collateral,
        liquidation_price,
        timestamp: order.timestamp,
        is_active: true,
    };

    table::add(&mut trading_state.positions, position_id, position);

    // Add to user positions
    if (!table::contains(&trading_state.user_positions, order.trader)) {
        table::add(&mut trading_state.user_positions, order.trader, vector::empty());
    };
    let user_positions = table::borrow_mut(&mut trading_state.user_positions, order.trader);
    vector::push_back(user_positions, position_id);

    // Mark order as inactive
    order.is_active = false;

    event::emit(OrderExecutedEvent {
        order_id,
        position_id,
        execution_price,
    });
}

   public entry fun close_position(account: &signer, trading_engine_addr: address, position_id: u64) acquires TradingState {
    let account_addr = signer::address_of(account);
    let trading_state = borrow_global_mut<TradingState>(trading_engine_addr);
    assert!(!trading_state.is_paused, E_CONTRACT_PAUSED);
    assert!(table::contains(&trading_state.positions, position_id), E_POSITION_NOT_FOUND);

    let position = table::borrow_mut(&mut trading_state.positions, position_id);
    assert!(position.trader == account_addr, E_NOT_AUTHORIZED);
    assert!(position.is_active, E_POSITION_NOT_FOUND);

    // Get current price with proper scaling
    assert!(table::contains(&trading_state.price_data, position.market), E_PRICE_FEED_NOT_FOUND);
    let price_data = table::borrow(&trading_state.price_data, position.market);
    let scaled_price = price_data.price / 10_000_000_000; // Scale from 1e18 to 1e8
    let current_price = if (scaled_price > (18446744073709551615u256)) {
        18446744073709551615u64
    } else {
        scaled_price as u64
    };

    // Calculate PnL
    let (pnl, is_profit) = calculate_pnl(position.entry_price, current_price, position.size, position.is_long);
    let fee = (position.size * trading_state.trading_fee) / 10000;
    
    // Deallocate liquidity
    pool_v2::deallocate_liquidity(trading_state.pool_address, position.market, position.is_long, position.size);

    // Collect trading fees
    pool_v2::collect_trading_fees(trading_state.pool_address, position.market, fee);

    // Process profit/loss
    let user_collateral = table::borrow_mut(&mut trading_state.user_collateral, account_addr);
    
    if (is_profit) {
        let profit = if (pnl > fee) pnl - fee else 0;
        if (profit > 0) {
            let profit_processed = pool_v2::process_profit(trading_state.pool_address, position.market, position.is_long, profit);
            assert!(profit_processed, E_INSUFFICIENT_LIQUIDITY);
            *user_collateral = *user_collateral + profit;
        };
    } else {
        let total_loss = pnl + fee;
        pool_v2::process_loss(trading_state.pool_address, position.market, position.is_long, total_loss);
        if (*user_collateral >= total_loss) {
            *user_collateral = *user_collateral - total_loss;
        } else {
            *user_collateral = 0;
        };
    };

    position.is_active = false;

    event::emit(PositionClosedEvent {
        position_id,
        trader: account_addr,
        pnl: if (is_profit) pnl else pnl,
        is_profit,
    });
}
    public entry fun liquidate_position(account: &signer, trading_engine_addr: address, position_id: u64) acquires TradingState {
    let trading_state = borrow_global_mut<TradingState>(trading_engine_addr);
    assert!(table::contains(&trading_state.positions, position_id), E_POSITION_NOT_FOUND);

    // Check if position is liquidatable first
    assert!(is_liquidatable_internal(trading_state, position_id), E_POSITION_NOT_FOUND);

    let position = table::borrow_mut(&mut trading_state.positions, position_id);
    assert!(position.is_active, E_POSITION_NOT_FOUND);

    // Store values we need
    let market = position.market;
    let is_long = position.is_long;
    let size = position.size;
    let collateral = position.collateral;
    let trader = position.trader;

    // Get current price with proper scaling
    let price_data = table::borrow(&trading_state.price_data, market);
    let scaled_price = price_data.price / 10_000_000_000; // Scale from 1e18 to 1e8
    let current_price = if (scaled_price > (18446744073709551615u256)) {
        18446744073709551615u64
    } else {
        scaled_price as u64
    };

    // Calculate liquidation bonus
    let liquidation_bonus = (collateral * pool_v2::get_liquidation_bonus()) / 10000;
    let remaining_collateral = if (collateral > liquidation_bonus) {
        collateral - liquidation_bonus
    } else {
        0
    };

    // Deallocate liquidity
    pool_v2::deallocate_liquidity(trading_state.pool_address, market, is_long, size);

    // Process remaining collateral as loss
    if (remaining_collateral > 0) {
        pool_v2::process_loss(trading_state.pool_address, market, is_long, remaining_collateral);
    };

    position.is_active = false;

    event::emit(PositionLiquidatedEvent {
        position_id,
        trader,
        liquidation_price: current_price,
    });
}

    // Helper functions

    fun calculate_liquidation_price_safe(entry_price: u64, leverage: u64, is_long: bool): u64 {
    // Use percentage calculation without large precision multipliers
    let liquidation_percent = LIQUIDATION_THRESHOLD; // 90
    let safety_margin = 100 - liquidation_percent; // 10
    
    if (is_long) {
        // liquidation_price = entry_price * (1 - safety_margin / (leverage * 100))
        let denominator = leverage * 100;
        let numerator = denominator - safety_margin;
        (entry_price * numerator) / denominator
    } else {
        // liquidation_price = entry_price * (1 + safety_margin / (leverage * 100))
        let denominator = leverage * 100;
        let numerator = denominator + safety_margin;
        (entry_price * numerator) / denominator
    } }

    fun safe_multiply_u64(a: u64, b: u64): u64 {
    let result = (a as u128) * (b as u128);
    let max_u64 = 18446744073709551615u128;
    if (result > max_u64) {
        18446744073709551615u64 // Return max u64 value
    } else {
        result as u64
    }
}
    fun check_liquidity_available(pool_address: address, market: String, is_long: bool, required_liquidity: u64): bool {
        let (long_pool, short_pool, _, _, utilization) = pool_v2::get_pool_info(pool_address, market);
        let max_utilization = pool_v2::get_max_pool_utilization();
        
        if (utilization >= max_utilization) return false;
        
        let total_pool_value = pool_v2::get_total_pool_value(pool_address);
        let total_allocated = long_pool + short_pool;
        let new_total_allocated = total_allocated + required_liquidity;
        let max_allocation = (total_pool_value * max_utilization) / 100;
        
        if (new_total_allocated > max_allocation) return false;
        
        let counterparty_pool = if (is_long) short_pool else long_pool;
        counterparty_pool >= required_liquidity / 2
    }

   fun calculate_pnl(entry_price: u64, current_price: u64, size: u64, is_long: bool): (u64, bool) {
    if (is_long) {
        if (current_price > entry_price) {
            let price_diff = current_price - entry_price;
            // Use safer multiplication: check if price_diff * size would overflow
            // Max u64 = 18,446,744,073,709,551,615
            // If price_diff > MAX_U64 / size, then overflow will occur
            let max_price_diff = 18446744073709551615u64 / size;
            if (price_diff > max_price_diff) {
                // Handle overflow case - return maximum possible profit
                (18446744073709551615u64 / PRICE_PRECISION, true)
            } else {
                let profit = (price_diff * size) / PRICE_PRECISION;
                (profit, true)
            }
        } else {
            let price_diff = entry_price - current_price;
            let max_price_diff = 18446744073709551615u64 / size;
            if (price_diff > max_price_diff) {
                (18446744073709551615u64 / PRICE_PRECISION, false)
            } else {
                let loss = (price_diff * size) / PRICE_PRECISION;
                (loss, false)
            }
        }
    } else {
        if (entry_price > current_price) {
            let price_diff = entry_price - current_price;
            let max_price_diff = 18446744073709551615u64 / size;
            if (price_diff > max_price_diff) {
                (18446744073709551615u64 / PRICE_PRECISION, true)
            } else {
                let profit = (price_diff * size) / PRICE_PRECISION;
                (profit, true)
            }
        } else {
            let price_diff = current_price - entry_price;
            let max_price_diff = 18446744073709551615u64 / size;
            if (price_diff > max_price_diff) {
                (18446744073709551615u64 / PRICE_PRECISION, false)
            } else {
                let loss = (price_diff * size) / PRICE_PRECISION;
                (loss, false)
            }
        }
    }
}

fun calculate_liquidation_price(entry_price: u64, leverage: u64, is_long: bool): u64 {
    // Instead of: let liquidation_threshold = (PRECISION * LIQUIDATION_THRESHOLD) / 100;
    // Use safer calculation to avoid overflow
    let liquidation_percentage = LIQUIDATION_THRESHOLD; // 90
    let leverage_factor = leverage;
    
    if (is_long) {
        // For long positions: liquidation_price = entry_price * (1 - liquidation_threshold / (leverage * 100))
        // Rearranged to avoid overflow: entry_price * (leverage * 100 - liquidation_threshold) / (leverage * 100)
        let numerator = (leverage * 100) - liquidation_percentage;
        (entry_price * numerator) / (leverage * 100)
    } else {
        // For short positions: liquidation_price = entry_price * (1 + liquidation_threshold / (leverage * 100))
        let numerator = (leverage * 100) + liquidation_percentage;
        (entry_price * numerator) / (leverage * 100)
    }
}

    fun get_available_collateral_internal(trading_state: &TradingState, user: address): u64 {
        if (!table::contains(&trading_state.user_collateral, user)) {
            return 0
        };
        
        let total_collateral = *table::borrow(&trading_state.user_collateral, user);
        let used_collateral = 0;
        
        // Check positions
        if (table::contains(&trading_state.user_positions, user)) {
            let user_positions = table::borrow(&trading_state.user_positions, user);
            let i = 0;
            while (i < vector::length(user_positions)) {
                let position_id = *vector::borrow(user_positions, i);
                let position = table::borrow(&trading_state.positions, position_id);
                if (position.is_active) {
                    used_collateral = used_collateral + position.collateral;
                };
                i = i + 1;
            };
        };
        
        // Check orders
        if (table::contains(&trading_state.user_orders, user)) {
            let user_orders = table::borrow(&trading_state.user_orders, user);
            let i = 0;
            while (i < vector::length(user_orders)) {
                let order_id = *vector::borrow(user_orders, i);
                let order = table::borrow(&trading_state.orders, order_id);
                if (order.is_active) {
                    used_collateral = used_collateral + order.collateral;
                };
                i = i + 1;
            };
        };
        
        if (total_collateral > used_collateral) {
            total_collateral - used_collateral
        } else {
            0
        }
    }

   fun is_liquidatable_internal(trading_state: &TradingState, position_id: u64): bool {
    let position = table::borrow(&trading_state.positions, position_id);
    if (!position.is_active) return false;
    
    if (!table::contains(&trading_state.price_data, position.market)) return false;
    
    let price_data = table::borrow(&trading_state.price_data, position.market);
    let scaled_price = price_data.price / 10_000_000_000; // Scale from 1e18 to 1e8
    let current_price = if (scaled_price > (18446744073709551615u256)) {
        18446744073709551615u64
    } else {
        scaled_price as u64
    };
    
    let (pnl, is_profit) = calculate_pnl(position.entry_price, current_price, position.size, position.is_long);
    
    let current_collateral = if (is_profit) {
        position.collateral
    } else {
        if (pnl >= position.collateral) return true;
        position.collateral - pnl
    };
    
    (current_collateral * 100) / position.collateral <= (100 - LIQUIDATION_THRESHOLD)
}


    fun calculate_total_utilized_internal(trading_state: &TradingState, pool_address: address): u64 {
        let total_utilized = 0;
        let i = 0;
        while (i < vector::length(&trading_state.supported_markets)) {
            let market = vector::borrow(&trading_state.supported_markets, i);
            let (long_pool, short_pool, _, _, _) = pool_v2::get_pool_info(pool_address, *market);
            total_utilized = total_utilized + long_pool + short_pool;
            i = i + 1;
        };
        total_utilized
    }

    fun calculate_total_fees_internal(trading_state: &TradingState, pool_address: address): u64 {
        let total_fees = 0;
        let i = 0;
        while (i < vector::length(&trading_state.supported_markets)) {
            let market = vector::borrow(&trading_state.supported_markets, i);
            let (_, _, _, fees_collected, _) = pool_v2::get_pool_info(pool_address, *market);
            total_fees = total_fees + fees_collected;
            i = i + 1;
        };
        total_fees
    }

    // View functions
    #[view]
    public fun get_available_collateral(trading_engine_addr: address, user: address): u64 acquires TradingState {
        let trading_state = borrow_global<TradingState>(trading_engine_addr);
        get_available_collateral_internal(trading_state, user)
    }
     #[view]
    public fun get_position(trading_engine_addr: address, position_id: u64): (address, String, bool, u64, u64, u64, u64, u64, u64, bool) acquires TradingState {
        let trading_state = borrow_global<TradingState>(trading_engine_addr);
        let position = table::borrow(&trading_state.positions, position_id);
        (
            position.trader,
            position.market,
            position.is_long,
            position.size,
            position.entry_price,
            position.leverage,
            position.collateral,
            position.liquidation_price,
            position.timestamp,
            position.is_active
        )
    }
    
#[view]
public fun get_current_price(trading_engine_addr: address, market: String): u64 acquires TradingState {
    let trading_state = borrow_global<TradingState>(trading_engine_addr);
    let price_data = table::borrow(&trading_state.price_data, market);

    // The price comes in with 18 decimals, we need to scale it down to 8 decimals for PRICE_PRECISION
    // Safe casting with proper bounds checking
    let scaled_price = price_data.price / 10_000_000_000; // Divide by 1e10 to go from 1e18 to 1e8
    
    // Ensure the value fits in u64
    if (scaled_price > (18446744073709551615u256)) { // u64::MAX
        return 18446744073709551615u64; // Return max u64 value
    };
    
    scaled_price as u64
}



    #[view]
    public fun is_liquidatable(trading_engine_addr: address, position_id: u64): bool acquires TradingState {
        let trading_state = borrow_global<TradingState>(trading_engine_addr);
        is_liquidatable_internal(trading_state, position_id)
    }

    #[view]
    public fun get_usdc_balance(user: address, usdc_metadata: Object<Metadata>): u64 {
        let user_store = primary_fungible_store::primary_store(user, usdc_metadata);
        fungible_asset::balance(user_store)
    }

    // Emergency functions
    public entry fun pause_contract(account: &signer, trading_engine_addr: address) acquires TradingState {
        let account_addr = signer::address_of(account);
        let trading_state = borrow_global_mut<TradingState>(trading_engine_addr);
        assert!(account_addr == trading_state.owner, E_NOT_AUTHORIZED);
        trading_state.is_paused = true;
    }

    public entry fun unpause_contract(account: &signer, trading_engine_addr: address) acquires TradingState {
      let account_addr = signer::address_of(account);
        let trading_state = borrow_global_mut<TradingState>(trading_engine_addr);
        assert!(account_addr == trading_state.owner, E_NOT_AUTHORIZED);
        trading_state.is_paused = false;
    }

    public entry fun update_trading_fee(account: &signer, trading_engine_addr: address, new_fee: u64) acquires TradingState {
       let account_addr = signer::address_of(account);
        let trading_state = borrow_global_mut<TradingState>(trading_engine_addr);
        assert!(account_addr == trading_state.owner, E_NOT_AUTHORIZED);
        assert!(new_fee <= 1000, E_INVALID_LEVERAGE); // Max 10% fee
        trading_state.trading_fee = new_fee;
    }
}