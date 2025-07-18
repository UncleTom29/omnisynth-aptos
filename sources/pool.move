module omnisynth::pool_v3 {
    use std::signer;
    use std::string::{Self, String};
    use std::vector;
    use std::object;
    use aptos_framework::primary_fungible_store;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::event;
    use aptos_framework::timestamp;
    use aptos_std::table::{Self, Table};
    use std::option;

    // Error codes
    const E_NOT_AUTHORIZED: u64 = 1;
    const E_MARKET_NOT_SUPPORTED: u64 = 2;
    const E_INSUFFICIENT_LIQUIDITY: u64 = 3;
    const E_BELOW_MINIMUM_LIQUIDITY: u64 = 4;
    const E_INSUFFICIENT_SHARES: u64 = 5;
    const E_INSUFFICIENT_BALANCE: u64 = 6;
    const E_EXCEEDS_MAX_ALLOCATION: u64 = 7;
    const E_INSUFFICIENT_POOL: u64 = 8;
    const E_NO_REWARDS: u64 = 9;
    const E_INSUFFICIENT_INSURANCE: u64 = 10;
    const E_WOULD_BREAK_LIQUIDITY: u64 = 11;
    const E_INVALID_USDC_ADDRESS: u64 = 12;

    // Constants
    const INSURANCE_FEE: u64 = 10; // 10% of trading fees
    const MAX_POOL_UTILIZATION: u64 = 80; // 80% max utilization
    const LIQUIDATION_BONUS: u64 = 500; // 5% liquidation bonus
    const MIN_LIQUIDITY: u64 = 1000000; // 1 USDC minimum (6 decimals)
    const PRECISION: u64 = 1000000000000000000; // 1e18

    struct PoolInfo has store {
        long_pool: u64,
        short_pool: u64,
        total_volume: u64,
        fees_collected: u64,
        is_active: bool,
    }

    struct LiquidityProvider has store {
        shares: u64,
        last_reward_claim: u64,
        total_deposited: u64,
        total_withdrawn: u64,
    }

    struct PoolState has key {
        market_pools: Table<String, PoolInfo>,
        liquidity_providers: Table<address, LiquidityProvider>,
        supported_markets: Table<String, bool>,
        total_pool_value: u64,
        insurance_fund: u64,
        total_shares: u64,
        owner: address,
        usdc_metadata: option::Option<object::Object<Metadata>>,
    }

    #[event]
    struct PoolInitializedEvent has drop, store {
        pool_address: address,
        owner: address,
    }

    #[event]
    struct LiquidityAddedEvent has drop, store {
        provider: address,
        amount: u64,
        shares: u64,
    }

    #[event]
    struct LiquidityRemovedEvent has drop, store {
        provider: address,
        amount: u64,
        shares: u64,
    }

    #[event]
    struct TradingFeesCollectedEvent has drop, store {
        market: String,
        amount: u64,
    }

    #[event]
    struct InsuranceFundUsedEvent has drop, store {
        amount: u64,
        reason: String,
    }

    #[event]
    struct MarketAddedEvent has drop, store {
        market: String,
    }

    public entry fun initialize(account: &signer) {
        let account_addr = signer::address_of(account);
        
        let pool_state = PoolState {
            market_pools: table::new(),
            liquidity_providers: table::new(),
            supported_markets: table::new(),
            total_pool_value: 0,
            insurance_fund: 0,
            total_shares: 0,
            owner: account_addr,
            usdc_metadata: option::none(),
        };
        
        move_to(account, pool_state);
        
        event::emit(PoolInitializedEvent {
            pool_address: account_addr,
            owner: account_addr,
        });
    }

    // Add function to set USDC metadata after initialization
    public entry fun set_usdc_metadata(account: &signer, usdc_address: address) acquires PoolState {
        let account_addr = signer::address_of(account);
        let pool_state = borrow_global_mut<PoolState>(account_addr);
        assert!(account_addr == pool_state.owner, E_NOT_AUTHORIZED);
        
        let usdc_metadata = object::address_to_object<Metadata>(usdc_address);
        pool_state.usdc_metadata = option::some(usdc_metadata);
    }

    public entry fun add_market(account: &signer, market: String) acquires PoolState {
        let account_addr = signer::address_of(account);
        let pool_state = borrow_global_mut<PoolState>(account_addr);
        assert!(account_addr == pool_state.owner, E_NOT_AUTHORIZED);
        assert!(!table::contains(&pool_state.supported_markets, market), E_MARKET_NOT_SUPPORTED);
        
        table::add(&mut pool_state.supported_markets, market, true);
        table::add(&mut pool_state.market_pools, market, PoolInfo {
            long_pool: 0,
            short_pool: 0,
            total_volume: 0,
            fees_collected: 0,
            is_active: true,
        });

        event::emit(MarketAddedEvent { market });
    }

    public entry fun add_liquidity(account: &signer, pool_address: address, amount: u64) acquires PoolState {
        assert!(amount >= MIN_LIQUIDITY, E_BELOW_MINIMUM_LIQUIDITY);
        
        let account_addr = signer::address_of(account);
        let pool_state = borrow_global_mut<PoolState>(pool_address);
        
        // Transfer USDC if metadata is set
        if (option::is_some(&pool_state.usdc_metadata)) {
            let usdc_metadata = *option::borrow(&pool_state.usdc_metadata);
            primary_fungible_store::transfer(account, usdc_metadata, pool_address, amount);
        };

        // Calculate shares
        let shares = if (pool_state.total_shares == 0) {
            amount
        } else {
            (amount * pool_state.total_shares) / pool_state.total_pool_value
        };

        // Update provider info
        if (!table::contains(&pool_state.liquidity_providers, account_addr)) {
            table::add(&mut pool_state.liquidity_providers, account_addr, LiquidityProvider {
                shares: 0,
                last_reward_claim: timestamp::now_seconds(),
                total_deposited: 0,
                total_withdrawn: 0,
            });
        };

        let provider = table::borrow_mut(&mut pool_state.liquidity_providers, account_addr);
        provider.shares = provider.shares + shares;
        provider.total_deposited = provider.total_deposited + amount;
        provider.last_reward_claim = timestamp::now_seconds();

        pool_state.total_pool_value = pool_state.total_pool_value + amount;
        pool_state.total_shares = pool_state.total_shares + shares;

        event::emit(LiquidityAddedEvent {
            provider: account_addr,
            amount,
            shares,
        });
    }

    public entry fun remove_liquidity(account: &signer, pool_address: address, shares: u64) acquires PoolState {
        assert!(shares > 0, E_INSUFFICIENT_SHARES);
        
        let account_addr = signer::address_of(account);
        
        // Check withdrawal eligibility first
        let amount = {
            let pool_state = borrow_global<PoolState>(pool_address);
            assert!(table::contains(&pool_state.liquidity_providers, account_addr), E_INSUFFICIENT_SHARES);
            let provider = table::borrow(&pool_state.liquidity_providers, account_addr);
            assert!(provider.shares >= shares, E_INSUFFICIENT_SHARES);
            (shares * pool_state.total_pool_value) / pool_state.total_shares
        };
        
        // Check liquidity constraints
        assert!(can_withdraw_internal(pool_address, amount), E_WOULD_BREAK_LIQUIDITY);
        
        // Check pool balance (only if USDC metadata is set)
        let pool_state = borrow_global<PoolState>(pool_address);
        if (option::is_some(&pool_state.usdc_metadata)) {
            let usdc_metadata = *option::borrow(&pool_state.usdc_metadata);
            let pool_balance = primary_fungible_store::balance(pool_address, usdc_metadata);
            assert!(pool_balance >= amount, E_INSUFFICIENT_BALANCE);
        };

        // Now perform the withdrawal
        let pool_state = borrow_global_mut<PoolState>(pool_address);
        let provider = table::borrow_mut(&mut pool_state.liquidity_providers, account_addr);
        
        provider.shares = provider.shares - shares;
        provider.total_withdrawn = provider.total_withdrawn + amount;

        pool_state.total_pool_value = pool_state.total_pool_value - amount;
        pool_state.total_shares = pool_state.total_shares - shares;

        // Note: For withdrawing funds from the pool, you'll need to implement a mechanism
        // where the pool owner can authorize withdrawals, since regular accounts cannot
        // transfer funds they don't own directly
        
        event::emit(LiquidityRemovedEvent {
            provider: account_addr,
            amount,
            shares,
        });
    }

    // Pool owner function to process approved withdrawals
    public entry fun process_withdrawal(pool_owner: &signer, recipient: address, amount: u64) acquires PoolState {
        let owner_addr = signer::address_of(pool_owner);
        let pool_state = borrow_global<PoolState>(owner_addr);
        assert!(owner_addr == pool_state.owner, E_NOT_AUTHORIZED);
        
        if (option::is_some(&pool_state.usdc_metadata)) {
            let usdc_metadata = *option::borrow(&pool_state.usdc_metadata);
            primary_fungible_store::transfer(pool_owner, usdc_metadata, recipient, amount);
        };
    }

    public fun can_withdraw(pool_addr: address, amount: u64): bool acquires PoolState {
        can_withdraw_internal(pool_addr, amount)
    }

    fun can_withdraw_internal(pool_addr: address, amount: u64): bool acquires PoolState {
        let pool_state = borrow_global<PoolState>(pool_addr);
        let total_utilized = calculate_total_utilized_internal(pool_state);
        let available_liquidity = pool_state.total_pool_value - total_utilized;
        let min_required = (pool_state.total_pool_value * (100 - MAX_POOL_UTILIZATION)) / 100;
        
        (available_liquidity - amount) >= min_required
    }

    public fun allocate_liquidity(pool_addr: address, market: String, is_long: bool, amount: u64): bool acquires PoolState {
        let pool_state = borrow_global_mut<PoolState>(pool_addr);
        assert!(table::contains(&pool_state.supported_markets, market), E_MARKET_NOT_SUPPORTED);
        
        let pool = table::borrow_mut(&mut pool_state.market_pools, market);
        let total_allocated = pool.long_pool + pool.short_pool;
        let max_allocation = (pool_state.total_pool_value * MAX_POOL_UTILIZATION) / 100;
        
        assert!(total_allocated + amount <= max_allocation, E_EXCEEDS_MAX_ALLOCATION);
        
        if (is_long) {
            pool.long_pool = pool.long_pool + amount;
        } else {
            pool.short_pool = pool.short_pool + amount;
        };
        
        true
    }


  public entry fun allocate_liquidity_v2(
    pool_addr: address,
    market: String,
    is_long: bool,
    amount: u64
) acquires PoolState {
    let pool_state = borrow_global_mut<PoolState>(pool_addr);
    assert!(table::contains(&pool_state.supported_markets, market), E_MARKET_NOT_SUPPORTED);

    let pool = table::borrow_mut(&mut pool_state.market_pools, market);
    let total_allocated = pool.long_pool + pool.short_pool;
    let max_allocation = (pool_state.total_pool_value * MAX_POOL_UTILIZATION) / 100;

    assert!(total_allocated + amount <= max_allocation, E_EXCEEDS_MAX_ALLOCATION);

    if (is_long) {
        pool.long_pool = pool.long_pool + amount;
    } else {
        pool.short_pool = pool.short_pool + amount;
    };
}


    public entry fun deallocate_liquidity(pool_addr: address, market: String, is_long: bool, amount: u64) acquires PoolState {
        let pool_state = borrow_global_mut<PoolState>(pool_addr);
        let pool = table::borrow_mut(&mut pool_state.market_pools, market);
        
        if (is_long) {
            assert!(pool.long_pool >= amount, E_INSUFFICIENT_POOL);
            pool.long_pool = pool.long_pool - amount;
        } else {
            assert!(pool.short_pool >= amount, E_INSUFFICIENT_POOL);
            pool.short_pool = pool.short_pool - amount;
        };
    }

    public entry fun collect_trading_fees(pool_addr: address, market: String, fees: u64) acquires PoolState {
        let pool_state = borrow_global_mut<PoolState>(pool_addr);
        assert!(table::contains(&pool_state.supported_markets, market), E_MARKET_NOT_SUPPORTED);
        
        let pool = table::borrow_mut(&mut pool_state.market_pools, market);
        let insurance_fee = (fees * INSURANCE_FEE) / 100;
        let lp_fee = fees - insurance_fee;
        
        pool.fees_collected = pool.fees_collected + lp_fee;
        pool_state.insurance_fund = pool_state.insurance_fund + insurance_fee;
        pool_state.total_pool_value = pool_state.total_pool_value + lp_fee;
        
        event::emit(TradingFeesCollectedEvent { market, amount: fees });
    }

    public fun process_profit(pool_addr: address, market: String, is_long: bool, profit: u64): bool acquires PoolState {
        let pool_state = borrow_global_mut<PoolState>(pool_addr);
        let pool = table::borrow_mut(&mut pool_state.market_pools, market);
        
        let counterparty_pool = if (is_long) pool.short_pool else pool.long_pool;
        
        if (counterparty_pool >= profit) {
            // Normal case: counterparty pool covers profit
            if (is_long) {
                pool.short_pool = pool.short_pool - profit;
            } else {
                pool.long_pool = pool.long_pool - profit;
            };
            true
        } else {
            // Emergency case: use insurance fund
            let shortage = profit - counterparty_pool;
            
            if (pool_state.insurance_fund >= shortage) {
                if (is_long) {
                    pool.short_pool = 0;
                } else {
                    pool.long_pool = 0;
                };
                pool_state.insurance_fund = pool_state.insurance_fund - shortage;
                event::emit(InsuranceFundUsedEvent {
                    amount: shortage,
                    reason: string::utf8(b"Covering trading profits"),
                });
                true
            } else {
                // Critical case: insufficient funds
                false
            }
        }
    }

    public fun process_loss(pool_addr: address, market: String, is_long: bool, loss: u64) acquires PoolState {
        let pool_state = borrow_global_mut<PoolState>(pool_addr);
        let pool = table::borrow_mut(&mut pool_state.market_pools, market);
        
        if (is_long) {
            pool.long_pool = pool.long_pool + loss;
        } else {
            pool.short_pool = pool.short_pool + loss;
        };
        
        pool_state.total_pool_value = pool_state.total_pool_value + loss;
    }

    public fun get_lp_rewards(pool_addr: address, provider: address): u64 acquires PoolState {
        let pool_state = borrow_global<PoolState>(pool_addr);
        
        if (!table::contains(&pool_state.liquidity_providers, provider)) {
            return 0
        };
        
        let lp = table::borrow(&pool_state.liquidity_providers, provider);
        if (lp.shares == 0) {
            return 0
        };
        
        let total_fees = calculate_total_fees_internal(pool_state);
        (lp.shares * total_fees) / pool_state.total_shares
    }

    public entry fun claim_rewards(account: &signer, pool_address: address) acquires PoolState {
        let account_addr = signer::address_of(account);
        let rewards = get_lp_rewards(pool_address, account_addr);
        assert!(rewards > 0, E_NO_REWARDS);
        
        let pool_state = borrow_global_mut<PoolState>(pool_address);
        let provider = table::borrow_mut(&mut pool_state.liquidity_providers, account_addr);
        provider.last_reward_claim = timestamp::now_seconds();
        
        // Reset fee tracking (simplified)
        reset_fees_collected_internal(pool_state);
        
        // Note: Similar to withdrawals, reward distribution would need to be processed
        // by the pool owner via a separate function
    }

    // Pool owner function to process approved reward claims
    public entry fun process_reward_claim(pool_owner: &signer, recipient: address, amount: u64) acquires PoolState {
        let owner_addr = signer::address_of(pool_owner);
        let pool_state = borrow_global<PoolState>(owner_addr);
        assert!(owner_addr == pool_state.owner, E_NOT_AUTHORIZED);
        
        if (option::is_some(&pool_state.usdc_metadata)) {
            let usdc_metadata = *option::borrow(&pool_state.usdc_metadata);
            primary_fungible_store::transfer(pool_owner, usdc_metadata, recipient, amount);
        };
    }

    #[view]
    public fun get_pool_info(pool_addr: address, market: String): (u64, u64, u64, u64, u64) acquires PoolState {
        let pool_state = borrow_global<PoolState>(pool_addr);
        let pool = table::borrow(&pool_state.market_pools, market);
        
        let utilization = if (pool_state.total_pool_value > 0) {
            ((pool.long_pool + pool.short_pool) * 100) / pool_state.total_pool_value
        } else {
            0
        };
        
        (pool.long_pool, pool.short_pool, pool.total_volume, pool.fees_collected, utilization)
    }

    public entry fun emergency_withdraw(account: &signer, amount: u64) acquires PoolState {
        let account_addr = signer::address_of(account);
        let pool_state = borrow_global_mut<PoolState>(account_addr);
        assert!(account_addr == pool_state.owner, E_NOT_AUTHORIZED);
        assert!(pool_state.insurance_fund >= amount, E_INSUFFICIENT_INSURANCE);
        
        pool_state.insurance_fund = pool_state.insurance_fund - amount;
        
        // Transfer USDC from insurance fund
        if (option::is_some(&pool_state.usdc_metadata)) {
            let usdc_metadata = *option::borrow(&pool_state.usdc_metadata);
            primary_fungible_store::transfer(account, usdc_metadata, pool_state.owner, amount);
        };
    }

    // Helper functions
    fun calculate_total_utilized(pool_addr: address): u64 acquires PoolState {
        let pool_state = borrow_global<PoolState>(pool_addr);
        calculate_total_utilized_internal(pool_state)
    }

    fun calculate_total_utilized_internal(pool_state: &PoolState): u64 {
        let total_utilized = 0u64;
        
        // In a real implementation, you'd iterate through all markets
        // For now, we'll check the main markets
        let markets = vector::empty<String>();
        vector::push_back(&mut markets, string::utf8(b"BTC/USD"));
        vector::push_back(&mut markets, string::utf8(b"ETH/USD"));
        vector::push_back(&mut markets, string::utf8(b"APT/USD"));
        
        let i = 0;
        while (i < vector::length(&markets)) {
            let market = vector::borrow(&markets, i);
            if (table::contains(&pool_state.market_pools, *market)) {
                let pool = table::borrow(&pool_state.market_pools, *market);
                total_utilized = total_utilized + pool.long_pool + pool.short_pool;
            };
            i = i + 1;
        };
        
        total_utilized
    }

    fun calculate_total_fees(pool_addr: address): u64 acquires PoolState {
        let pool_state = borrow_global<PoolState>(pool_addr);
        calculate_total_fees_internal(pool_state)
    }

    fun calculate_total_fees_internal(pool_state: &PoolState): u64 {
        let total_fees = 0;
        
        let markets = vector::empty<String>();
        vector::push_back(&mut markets, string::utf8(b"BTC/USD"));
        vector::push_back(&mut markets, string::utf8(b"ETH/USD"));
        vector::push_back(&mut markets, string::utf8(b"APT/USD"));
        
        let i = 0;
        while (i < vector::length(&markets)) {
            let market = vector::borrow(&markets, i);
            if (table::contains(&pool_state.market_pools, *market)) {
                let pool = table::borrow(&pool_state.market_pools, *market);
                total_fees = total_fees + pool.fees_collected;
            };
            i = i + 1;
        };
        
        total_fees
    }

    fun reset_fees_collected(pool_addr: address) acquires PoolState {
        let pool_state = borrow_global_mut<PoolState>(pool_addr);
        reset_fees_collected_internal(pool_state);
    }

    fun reset_fees_collected_internal(pool_state: &mut PoolState) {
        let markets = vector::empty<String>();
        vector::push_back(&mut markets, string::utf8(b"BTC/USD"));
        vector::push_back(&mut markets, string::utf8(b"ETH/USD"));
        vector::push_back(&mut markets, string::utf8(b"APT/USD"));
        
        let i = 0;
        while (i < vector::length(&markets)) {
            let market = vector::borrow(&markets, i);
            if (table::contains(&pool_state.market_pools, *market)) {
                let pool = table::borrow_mut(&mut pool_state.market_pools, *market);
                pool.fees_collected = 0;
            };
            i = i + 1;
        };
    }

    // View functions
     #[view]
    public fun get_total_pool_value(pool_addr: address): u64 acquires PoolState {
        borrow_global<PoolState>(pool_addr).total_pool_value
    }

     #[view]
    public fun get_insurance_fund(pool_addr: address): u64 acquires PoolState {
        borrow_global<PoolState>(pool_addr).insurance_fund
    }

     #[view]
    public fun get_liquidation_bonus(): u64 {
        LIQUIDATION_BONUS
    }

     #[view]
    public fun get_max_pool_utilization(): u64 {
        MAX_POOL_UTILIZATION
    }

    #[view]
    public fun get_pool_usdc_balance(pool_addr: address): u64 acquires PoolState {
        let pool_state = borrow_global<PoolState>(pool_addr);
        if (option::is_some(&pool_state.usdc_metadata)) {
            let usdc_metadata = *option::borrow(&pool_state.usdc_metadata);
            primary_fungible_store::balance(pool_addr, usdc_metadata)
        } else {
            0
        }
    }
}