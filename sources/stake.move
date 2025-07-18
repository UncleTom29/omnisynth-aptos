module omnistake::stake {
    use std::signer;
    use std::vector;
    use std::string::String;
    use std::event;
    use std::timestamp;
    use std::error;
    use std::table::{Self, Table};
    
    use aptos_framework::coin::{Self};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::account;
    use aptos_framework::randomness;
    use aptos_framework::resource_account;
    
    // Custom errors
    const E_INVALID_AMOUNT: u64 = 1;
    const E_INVALID_VALIDATOR: u64 = 2;
    const E_INSUFFICIENT_BALANCE: u64 = 3;
    const E_INVALID_UNSTAKE_REQUEST: u64 = 4;
    const E_UNSTAKING_PERIOD_NOT_PASSED: u64 = 5;
    const E_REQUEST_ALREADY_PROCESSED: u64 = 6;
    const E_INVALID_PRICE_FEED: u64 = 7;
    const E_NOT_ADMIN: u64 = 8;
    const E_POOL_NOT_INITIALIZED: u64 = 9;
    const E_NOT_FOUND: u64 = 1;
    
    // Constants
    const CALLBACK_GAS_LIMIT: u32 = 200000;
    const REQUEST_CONFIRMATIONS: u16 = 3;
    const NUM_WORDS: u32 = 1;
    const ANNUAL_REWARD_RATE: u64 = 500; // 5% annual in basis points
    const PROTOCOL_FEE: u64 = 1000; // 10% of rewards in basis points
    const MIN_STAKE_AMOUNT: u64 = 100000000; // 1 APT (8 decimals)
    const UNSTAKING_PERIOD: u64 = 604800; // 7 days in seconds
    const BASIS_POINTS: u64 = 10000;
    const DAY_IN_SECONDS: u64 = 86400;
    
    // Liquid staking token info
    struct StakeToken has key {
        name: String,
        symbol: String,
        decimals: u8,
    }
    
    // Validator information
    struct Validator has store {
        validator_address: address,
        staked_amount: u64,
        reward_debt: u64,
        is_active: bool,
        performance: u64, // Performance score out of 100
        commission: u64, // Commission rate in basis points
    }
    
 struct UnstakeRequest has copy, drop, store {
    amount: u64, // USDC amount equivalent
    timestamp: u64,
    processed: bool,
}

    
    // User stake information
    struct UserStake has store {
        staked_amount: u64,
        share_balance: u64,
        unstake_requests: vector<UnstakeRequest>,
    }
    
    // Main staking pool
    struct StakePool has key {
        // Token management
        usdc_balance: u64, // For compatibility, tracking USDC equivalent
        share_supply: u64,
        
        // Validator management
        validators: Table<u64, Validator>,
        validator_count: u64,
        selected_validator_id: u64,
        
        // User management
        user_stakes: Table<address, UserStake>,
        
        // Pool parameters
        total_staked: u64,
        total_apt_rewards: u64,
        annual_reward_rate: u64,
        protocol_fee: u64,
        last_reward_distribution: u64,
        min_stake_amount: u64,
        unstaking_period: u64,
        
        // Admin
        admin: address,
        
        // Randomness
        last_random_request: u64,
        pending_requests: Table<u64, bool>,
        
        // APT price in USDC (for compatibility)
        apt_price_usdc: u64, // Price in 6 decimals
        
        // Resource account capability
        signer_cap: account::SignerCapability,
    }
    
    #[event]
    struct StakedEvent has drop, store {
        user: address,
        apt_amount: u64,
        shares: u64,
    }
    
    #[event]
    struct UnstakeRequestedEvent has drop, store {
        user: address,
        apt_amount: u64,
        request_id: u64,
    }
    
    #[event]
    struct UnstakedEvent has drop, store {
        user: address,
        apt_amount: u64,
        shares: u64,
    }
    
    #[event]
    struct ValidatorAddedEvent has drop, store {
        id: u64,
        validator: address,
        commission: u64,
    }
    
    #[event]
    struct ValidatorUpdatedEvent has drop, store {
        id: u64,
        is_active: bool,
        performance: u64,
    }
    
    #[event]
    struct APTRewardsDistributedEvent has drop, store {
        apt_amount: u64,
        usdc_value: u64,
        timestamp: u64,
    }
    
    #[event]
    struct ValidatorSelectedEvent has drop, store {
        id: u64,
        validator: address,
    }
    
    #[event]
    struct ProtocolFeeUpdatedEvent has drop, store {
        new_fee: u64,
    }
    
    // Initialize the staking pool
    public entry fun initialize(
        admin: &signer,
        name: String,
        symbol: String,
        initial_apt_price: u64,
    ) {
        let admin_addr = signer::address_of(admin);
        
        // Create resource account
        let (resource_signer, signer_cap) = account::create_resource_account(admin, b"omnistake_pool");
        
        // Initialize stake token
        move_to(&resource_signer, StakeToken {
            name,
            symbol,
            decimals: 8,
        });
        
        // Initialize stake pool
        move_to(&resource_signer, StakePool {
            usdc_balance: 0,
            share_supply: 0,
            validators: table::new(),
            validator_count: 0,
            selected_validator_id: 0,
            user_stakes: table::new(),
            total_staked: 0,
            total_apt_rewards: 0,
            annual_reward_rate: ANNUAL_REWARD_RATE,
            protocol_fee: PROTOCOL_FEE,
            last_reward_distribution: timestamp::now_seconds(),
            min_stake_amount: MIN_STAKE_AMOUNT,
            unstaking_period: UNSTAKING_PERIOD,
            admin: admin_addr,
            last_random_request: 0,
            pending_requests: table::new(),
            apt_price_usdc: initial_apt_price,
            signer_cap,
        });
    }
    
    // Stake APT and receive liquid staking tokens
    public entry fun stake(user: &signer, apt_amount: u64) acquires StakePool {
        assert!(apt_amount >= MIN_STAKE_AMOUNT, error::invalid_argument(E_INVALID_AMOUNT));
        
        let user_addr = signer::address_of(user);
        let resource_addr = account::create_resource_address(&@omnistake, b"omnistake_pool");
        let pool = borrow_global_mut<StakePool>(resource_addr);
        
        // Calculate shares
        let shares = if (pool.share_supply == 0) {
            apt_amount
        } else {
            (apt_amount * pool.share_supply) / pool.total_staked
        };
        
        // Transfer APT to pool
        let apt_coins = coin::withdraw<AptosCoin>(user, apt_amount);
        coin::deposit(resource_addr, apt_coins);
        
        // Update user stake
        if (!table::contains(&pool.user_stakes, user_addr)) {
            table::add(&mut pool.user_stakes, user_addr, UserStake {
                staked_amount: 0,
                share_balance: 0,
                unstake_requests: vector::empty(),
            });
        };
        
        let user_stake = table::borrow_mut(&mut pool.user_stakes, user_addr);
        user_stake.staked_amount = user_stake.staked_amount + apt_amount;
        user_stake.share_balance = user_stake.share_balance + shares;
        
        // Update pool totals
        pool.total_staked = pool.total_staked + apt_amount;
        pool.share_supply = pool.share_supply + shares;
        
        // Emit event
        event::emit(StakedEvent {
            user: user_addr,
            apt_amount,
            shares,
        });
    }
    
    // Request unstaking of shares
    public entry fun request_unstake(user: &signer, shares: u64) acquires StakePool {
        assert!(shares > 0, error::invalid_argument(E_INVALID_AMOUNT));
        
        let user_addr = signer::address_of(user);
        let resource_addr = account::create_resource_address(&@omnistake, b"omnistake_pool");
        let pool = borrow_global_mut<StakePool>(resource_addr);
        
        assert!(table::contains(&pool.user_stakes, user_addr), error::not_found(E_INSUFFICIENT_BALANCE));
        
        let user_stake = table::borrow_mut(&mut pool.user_stakes, user_addr);
        assert!(user_stake.share_balance >= shares, error::invalid_argument(E_INSUFFICIENT_BALANCE));
        
        let apt_amount = (shares * pool.total_staked) / pool.share_supply;
        
        // Create unstake request
        let request = UnstakeRequest {
            amount: apt_amount,
            timestamp: timestamp::now_seconds(),
            processed: false,
        };
        
        vector::push_back(&mut user_stake.unstake_requests, request);
        
        // Burn shares
        user_stake.share_balance = user_stake.share_balance - shares;
        pool.share_supply = pool.share_supply - shares;
        
        let request_id = vector::length(&user_stake.unstake_requests) - 1;
        
        // Emit event
        event::emit(UnstakeRequestedEvent {
            user: user_addr,
            apt_amount,
            request_id,
        });
    }
    
    // Process unstake request after waiting period
    public entry fun process_unstake(user: &signer, request_id: u64) acquires StakePool {
        let user_addr = signer::address_of(user);
        let resource_addr = account::create_resource_address(&@omnistake, b"omnistake_pool");
        let pool = borrow_global_mut<StakePool>(resource_addr);
        
        assert!(table::contains(&pool.user_stakes, user_addr), error::not_found(E_INVALID_UNSTAKE_REQUEST));
        
        let user_stake = table::borrow_mut(&mut pool.user_stakes, user_addr);
        assert!(request_id < vector::length(&user_stake.unstake_requests), error::invalid_argument(E_INVALID_UNSTAKE_REQUEST));
        
        let request = vector::borrow_mut(&mut user_stake.unstake_requests, request_id);
        assert!(!request.processed, error::invalid_state(E_REQUEST_ALREADY_PROCESSED));
        assert!(
            timestamp::now_seconds() >= request.timestamp + pool.unstaking_period,
            error::invalid_state(E_UNSTAKING_PERIOD_NOT_PASSED)
        );
        
        let apt_amount = request.amount;
        assert!(coin::balance<AptosCoin>(resource_addr) >= apt_amount, error::invalid_argument(E_INSUFFICIENT_BALANCE));
        
        // Mark request as processed
        request.processed = true;
        
        // Update user stake
        user_stake.staked_amount = user_stake.staked_amount - apt_amount;
        
        // Update pool total
        pool.total_staked = pool.total_staked - apt_amount;
        
        // Transfer APT back to user
        let resource_signer = account::create_signer_with_capability(&pool.signer_cap);
        let apt_coins = coin::withdraw<AptosCoin>(&resource_signer, apt_amount);
        coin::deposit(user_addr, apt_coins);
        
        // Emit event
        event::emit(UnstakedEvent {
            user: user_addr,
            apt_amount,
            shares: 0,
        });
    }
    
    // Add a new validator (admin only)
    public entry fun add_validator(
        admin: &signer,
        validator_address: address,
        commission: u64,
    ) acquires StakePool {
        let resource_addr = account::create_resource_address(&@omnistake, b"omnistake_pool");
        let pool = borrow_global_mut<StakePool>(resource_addr);
        assert!(signer::address_of(admin) == pool.admin, error::permission_denied(E_NOT_ADMIN));
        assert!(validator_address != @0x0, error::invalid_argument(E_INVALID_VALIDATOR));
        assert!(commission <= 5000, error::invalid_argument(E_INVALID_VALIDATOR)); // Max 50% commission
        
        let validator = Validator {
            validator_address,
            staked_amount: 0,
            reward_debt: 0,
            is_active: true,
            performance: 100,
            commission,
        };
        
        table::add(&mut pool.validators, pool.validator_count, validator);
        
        // Emit event
        event::emit(ValidatorAddedEvent {
            id: pool.validator_count,
            validator: validator_address,
            commission,
        });
        
        pool.validator_count = pool.validator_count + 1;
    }
    
    // Update validator status and performance (admin only)
    public entry fun update_validator(
        admin: &signer,
        validator_id: u64,
        is_active: bool,
        performance: u64,
    ) acquires StakePool {
        let resource_addr = account::create_resource_address(&@omnistake, b"omnistake_pool");
        let pool = borrow_global_mut<StakePool>(resource_addr);
        assert!(signer::address_of(admin) == pool.admin, error::permission_denied(E_NOT_ADMIN));
        assert!(validator_id < pool.validator_count, error::invalid_argument(E_INVALID_VALIDATOR));
        assert!(performance <= 100, error::invalid_argument(E_INVALID_VALIDATOR));
        
        let validator = table::borrow_mut(&mut pool.validators, validator_id);
        validator.is_active = is_active;
        validator.performance = performance;
        
        // Emit event
        event::emit(ValidatorUpdatedEvent {
            id: validator_id,
            is_active,
            performance,
        });
    }
    
    // Select random validator using Aptos randomness
    #[lint::allow_unsafe_randomness]
    public entry fun select_random_validator(admin: &signer) acquires StakePool {
        let resource_addr = account::create_resource_address(&@omnistake, b"omnistake_pool");
        let pool = borrow_global_mut<StakePool>(resource_addr);
        assert!(signer::address_of(admin) == pool.admin, error::permission_denied(E_NOT_ADMIN));
        assert!(pool.validator_count > 0, error::invalid_argument(E_INVALID_VALIDATOR));
        
        // Generate random number
        let random_bytes = randomness::u64_range(0, 1000000);
        
        // Calculate total weight based on performance
        let total_weight = 0;
        let i = 0;
        while (i < pool.validator_count) {
            if (table::contains(&pool.validators, i)) {
                let validator = table::borrow(&pool.validators, i);
                if (validator.is_active) {
                    total_weight = total_weight + validator.performance;
                };
            };
            i = i + 1;
        };
        
        if (total_weight == 0) return;
        
        // Select validator based on weighted random
        let random_weight = random_bytes % total_weight;
        let current_weight = 0;
        
        i = 0;
        while (i < pool.validator_count) {
            if (table::contains(&pool.validators, i)) {
                let validator = table::borrow(&pool.validators, i);
                if (validator.is_active) {
                    current_weight = current_weight + validator.performance;
                    if (current_weight >= random_weight) {
                        pool.selected_validator_id = i;
                        
                        // Emit event
                        event::emit(ValidatorSelectedEvent {
                            id: i,
                            validator: validator.validator_address,
                        });
                        break
                    };
                };
            };
            i = i + 1;
        };
    }
    
    // Distribute APT rewards
    public entry fun distribute_apt_rewards(distributor: &signer) acquires StakePool {
        let resource_addr = account::create_resource_address(&@omnistake, b"omnistake_pool");
        let pool = borrow_global_mut<StakePool>(resource_addr);
        
        // Daily rewards check
        if (timestamp::now_seconds() < pool.last_reward_distribution + DAY_IN_SECONDS) return;
        
        let apt_reward = coin::balance<AptosCoin>(signer::address_of(distributor));
        if (apt_reward == 0) return;
        
        // Transfer APT rewards to pool
        let apt_coins = coin::withdraw<AptosCoin>(distributor, apt_reward);
        coin::deposit(resource_addr, apt_coins);
        
        // Convert APT to USDC value for compatibility
        let reward_value_usdc = (apt_reward * pool.apt_price_usdc) / 100000000; // 8 decimals to 6 decimals
        
        // Calculate protocol fee
        let protocol_fee_amount = (reward_value_usdc * pool.protocol_fee) / BASIS_POINTS;
        let stakers_reward = reward_value_usdc - protocol_fee_amount;
        
        // Update pool state
        pool.total_staked = pool.total_staked + stakers_reward;
        pool.total_apt_rewards = pool.total_apt_rewards + apt_reward;
        pool.last_reward_distribution = timestamp::now_seconds();
        
        // Protocol fee handling would need to be implemented based on requirements
        
        // Emit event
        event::emit(APTRewardsDistributedEvent {
            apt_amount: apt_reward,
            usdc_value: reward_value_usdc,
            timestamp: timestamp::now_seconds(),
        });
    }
    
    // Update protocol fee (admin only)
    public entry fun update_protocol_fee(admin: &signer, new_fee: u64) acquires StakePool {
        let resource_addr = account::create_resource_address(&@omnistake, b"omnistake_pool");
        let pool = borrow_global_mut<StakePool>(resource_addr);
        assert!(signer::address_of(admin) == pool.admin, error::permission_denied(E_NOT_ADMIN));
        assert!(new_fee <= 2000, error::invalid_argument(E_INVALID_AMOUNT)); // Max 20%
        
        pool.protocol_fee = new_fee;
        
        // Emit event
        event::emit(ProtocolFeeUpdatedEvent {
            new_fee,
        });
    }
    
    // Update reward rate (admin only)
    public entry fun update_reward_rate(admin: &signer, new_rate: u64) acquires StakePool {
        let resource_addr = account::create_resource_address(&@omnistake, b"omnistake_pool");
        let pool = borrow_global_mut<StakePool>(resource_addr);
        assert!(signer::address_of(admin) == pool.admin, error::permission_denied(E_NOT_ADMIN));
        assert!(new_rate <= 2000, error::invalid_argument(E_INVALID_AMOUNT)); // Max 20%
        
        pool.annual_reward_rate = new_rate;
    }
    
    // Update minimum stake amount (admin only)
    public entry fun update_min_stake_amount(admin: &signer, new_amount: u64) acquires StakePool {
        let resource_addr = account::create_resource_address(&@omnistake, b"omnistake_pool");
        let pool = borrow_global_mut<StakePool>(resource_addr);
        assert!(signer::address_of(admin) == pool.admin, error::permission_denied(E_NOT_ADMIN));
        
        pool.min_stake_amount = new_amount;
    }
    
    // Update unstaking period (admin only)
    public entry fun update_unstaking_period(admin: &signer, new_period: u64) acquires StakePool {
        let resource_addr = account::create_resource_address(&@omnistake, b"omnistake_pool");
        let pool = borrow_global_mut<StakePool>(resource_addr);
        assert!(signer::address_of(admin) == pool.admin, error::permission_denied(E_NOT_ADMIN));
        assert!(new_period <= 2592000, error::invalid_argument(E_INVALID_AMOUNT)); // Max 30 days
        
        pool.unstaking_period = new_period;
    }
    
    // Update APT price (admin only)
    public entry fun update_apt_price(admin: &signer, new_price: u64) acquires StakePool {
        let resource_addr = account::create_resource_address(&@omnistake, b"omnistake_pool");
        let pool = borrow_global_mut<StakePool>(resource_addr);
        assert!(signer::address_of(admin) == pool.admin, error::permission_denied(E_NOT_ADMIN));
        
        pool.apt_price_usdc = new_price;
    }
    
    // Get staking information for user
    public fun get_staking_info(user: address): (u64, u64, u64, u64, u64, u64, u64) acquires StakePool {
        let resource_addr = account::create_resource_address(&@omnistake, b"omnistake_pool");
        let pool = borrow_global<StakePool>(resource_addr);
        
        let user_stake_amount = if (table::contains(&pool.user_stakes, user)) {
            table::borrow(&pool.user_stakes, user).staked_amount
        } else {
            0
        };
        
        let user_shares = if (table::contains(&pool.user_stakes, user)) {
            table::borrow(&pool.user_stakes, user).share_balance
        } else {
            0
        };
        
        let share_price = if (pool.share_supply > 0) {
            (pool.total_staked * 100000000) / pool.share_supply // 8 decimals
        } else {
            100000000 // 1.0 in 8 decimals
        };
        
        (
            pool.total_staked,
            pool.total_apt_rewards,
            pool.annual_reward_rate,
            user_stake_amount,
            user_shares,
            share_price,
            pool.apt_price_usdc,
        )
    }
#[view]
public fun get_user_unstake_requests(
    user: address
): vector<UnstakeRequest> acquires StakePool {
    let resource_addr = account::create_resource_address(&@omnistake, b"omnistake_pool");
    let pool = borrow_global<StakePool>(resource_addr);

    if (!table::contains(&pool.user_stakes, user)) {
        return vector::empty<UnstakeRequest>();
    };

    let stake_entry = table::borrow(&pool.user_stakes, user);

    // Create a new vector and copy unstake requests into it
    let result = vector::empty<UnstakeRequest>();
    let src = &stake_entry.unstake_requests;
    let len = vector::length(src);
    let i = 0;
    while (i < len) {
        let r = vector::borrow(src, i);
        vector::push_back(&mut result, *r); // Safe because UnstakeRequest has copy semantics
        i = i + 1;
    };
    result
}


    
    // Emergency withdrawal (admin only)
    public entry fun emergency_withdraw(admin: &signer, amount: u64) acquires StakePool {
        let resource_addr = account::create_resource_address(&@omnistake, b"omnistake_pool");
        let pool = borrow_global<StakePool>(resource_addr);
        assert!(signer::address_of(admin) == pool.admin, error::permission_denied(E_NOT_ADMIN));
        assert!(amount <= coin::balance<AptosCoin>(resource_addr), error::invalid_argument(E_INSUFFICIENT_BALANCE));
        
        let resource_signer = account::create_signer_with_capability(&pool.signer_cap);
        let apt_coins = coin::withdraw<AptosCoin>(&resource_signer, amount);
        coin::deposit(signer::address_of(admin), apt_coins);
    }
    
    // Check if pool is initialized
    public fun is_initialized(): bool {
        let resource_addr = account::create_resource_address(&@omnistake, b"omnistake_pool");
        exists<StakePool>(resource_addr)
    }
    
    // Get pool admin
    public fun get_admin(): address acquires StakePool {
        let resource_addr = account::create_resource_address(&@omnistake, b"omnistake_pool");
        borrow_global<StakePool>(resource_addr).admin
    }
    
    // Get total staked amount
    public fun get_total_staked(): u64 acquires StakePool {
        let resource_addr = account::create_resource_address(&@omnistake, b"omnistake_pool");
        borrow_global<StakePool>(resource_addr).total_staked
    }
    
    // Get share supply
    public fun get_share_supply(): u64 acquires StakePool {
        let resource_addr = account::create_resource_address(&@omnistake, b"omnistake_pool");
        borrow_global<StakePool>(resource_addr).share_supply
    }
}