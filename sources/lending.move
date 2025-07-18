module omni_lending::lending {
    use std::error;
    use std::signer;
    use std::string::{Self, String};
    use std::timestamp;
    use std::vector;
    use std::option::{Self, Option};
    
    use aptos_framework::account;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::table::{Self, Table};
    use aptos_framework::type_info;
    
    // Custom USDC coin type (for testnet)
    struct USDC has store {}
    
    // Error codes
    const E_NOT_AUTHORIZED: u64 = 1;
    const E_INSUFFICIENT_COLLATERAL: u64 = 2;
    const E_EXCEEDS_COLLATERAL_CAPACITY: u64 = 3;
    const E_INSUFFICIENT_LIQUIDITY: u64 = 4;
    const E_INVALID_AMOUNT: u64 = 5;
    const E_POSITION_HEALTHY: u64 = 6;
    const E_NO_COLLATERAL: u64 = 7;
    const E_NO_DEBT: u64 = 8;
    const E_NO_LENDING: u64 = 9;
    const E_INSUFFICIENT_REWARDS: u64 = 10;
    const E_INVALID_PRICE: u64 = 11;
    const E_PROTOCOL_PAUSED: u64 = 12;
    const E_PRICE_TOO_STALE: u64 = 13;
    const E_CANNOT_LIQUIDATE_SELF: u64 = 14;
    const E_INVALID_ADDRESS: u64 = 15;
    const E_PROTOCOL_FEE_TOO_HIGH: u64 = 16;
    
    // Protocol constants
    const COLLATERAL_RATIO: u64 = 150;
    const LIQUIDATION_THRESHOLD: u64 = 120;
    const LIQUIDATION_BONUS: u64 = 10;
    const BASE_BORROW_RATE: u64 = 300;
    const BASE_REWARD_RATE: u64 = 500;
    const RATE_SLOPE: u64 = 2000;
    const PRECISION: u64 = 1000000000000000000; // 1e18
    const BASIS_POINTS: u64 = 10000;
    const SECONDS_PER_YEAR: u64 = 31536000; // 365 * 24 * 60 * 60
    const PRICE_FEED_STALENESS_THRESHOLD: u64 = 3600; // 1 hour
    
    // User account structure
    struct UserAccount has store {
        apt_collateral: u64,
        usdc_borrowed: u64,
        usdc_lent: u64,
        last_borrow_update: u64,
        last_lend_update: u64,
        accrued_borrow_interest: u64,
        accrued_lend_rewards: u64,
    }
    
    // Protocol state structure
    struct ProtocolState has store {
        total_apt_collateral: u64,
        total_usdc_borrowed: u64,
        total_usdc_lent: u64,
        total_apt_rewards: u64,
        borrow_rate: u64,
        lend_reward_rate: u64,
        last_rate_update: u64,
    }
    
    // Price feed data
    struct PriceFeedData has store {
        apt_usd_price: u64, // Price in USD with 8 decimals
        last_updated: u64,
    }
    
    // Global state
    struct GlobalState has key {
        protocol_state: ProtocolState,
        user_accounts: Table<address, UserAccount>,
        price_feed: PriceFeedData,
        protocol_fee: u64,
        min_collateral_amount: u64,
        min_lend_amount: u64,
        treasury: address,
        owner: address,
        paused: bool,
        
        // Reserve pools
        usdc_pool: Coin<USDC>,
        apt_rewards_pool: Coin<AptosCoin>,
        
        // Event handles
        collateral_deposited_events: EventHandle<CollateralDepositedEvent>,
        collateral_withdrawn_events: EventHandle<CollateralWithdrawnEvent>,
        usdc_borrowed_events: EventHandle<UsdcBorrowedEvent>,
        usdc_repaid_events: EventHandle<UsdcRepaidEvent>,
        usdc_lent_events: EventHandle<UsdcLentEvent>,
        usdc_withdrawn_from_lending_events: EventHandle<UsdcWithdrawnFromLendingEvent>,
        apt_rewards_claimed_events: EventHandle<AptRewardsClaimedEvent>,
        liquidated_events: EventHandle<LiquidatedEvent>,
        rates_updated_events: EventHandle<RatesUpdatedEvent>,
        protocol_fees_collected_events: EventHandle<ProtocolFeesCollectedEvent>,
    }
    
    // Events
    struct CollateralDepositedEvent has drop, store {
        user: address,
        apt_amount: u64,
        timestamp: u64,
    }
    
    struct CollateralWithdrawnEvent has drop, store {
        user: address,
        apt_amount: u64,
        timestamp: u64,
    }
    
    struct UsdcBorrowedEvent has drop, store {
        user: address,
        usdc_amount: u64,
        timestamp: u64,
    }
    
    struct UsdcRepaidEvent has drop, store {
        user: address,
        usdc_amount: u64,
        interest_paid: u64,
        timestamp: u64,
    }
    
    struct UsdcLentEvent has drop, store {
        user: address,
        usdc_amount: u64,
        timestamp: u64,
    }
    
    struct UsdcWithdrawnFromLendingEvent has drop, store {
        user: address,
        usdc_amount: u64,
        timestamp: u64,
    }
    
    struct AptRewardsClaimedEvent has drop, store {
        user: address,
        apt_amount: u64,
        timestamp: u64,
    }
    
    struct LiquidatedEvent has drop, store {
        borrower: address,
        liquidator: address,
        apt_seized: u64,
        usdc_repaid: u64,
        timestamp: u64,
    }
    
    struct RatesUpdatedEvent has drop, store {
        borrow_rate: u64,
        lend_reward_rate: u64,
        timestamp: u64,
    }
    
    struct ProtocolFeesCollectedEvent has drop, store {
        usdc_amount: u64,
        apt_amount: u64,
        timestamp: u64,
    }
    
    // Initialize the protocol
    public entry fun initialize(
        owner: &signer,
        treasury: address,
        initial_apt_usd_price: u64,
    ) {
        let owner_addr = signer::address_of(owner);
        
        assert!(!exists<GlobalState>(owner_addr), error::already_exists(0));
        assert!(treasury != @0x0, error::invalid_argument(E_INVALID_ADDRESS));
        
        let protocol_state = ProtocolState {
            total_apt_collateral: 0,
            total_usdc_borrowed: 0,
            total_usdc_lent: 0,
            total_apt_rewards: 0,
            borrow_rate: BASE_BORROW_RATE,
            lend_reward_rate: BASE_REWARD_RATE,
            last_rate_update: timestamp::now_seconds(),
        };
        
        let price_feed = PriceFeedData {
            apt_usd_price: initial_apt_usd_price,
            last_updated: timestamp::now_seconds(),
        };
        
        let global_state = GlobalState {
            protocol_state,
            user_accounts: table::new<address, UserAccount>(),
            price_feed,
            protocol_fee: 1000, // 10%
            min_collateral_amount: 100000000, // 1 APT (8 decimals)
            min_lend_amount: 100000000, // 100 USDC (6 decimals)
            treasury,
            owner: owner_addr,
            paused: false,
            
            usdc_pool: coin::zero<USDC>(),
            apt_rewards_pool: coin::zero<AptosCoin>(),
            
            collateral_deposited_events: account::new_event_handle<CollateralDepositedEvent>(owner),
            collateral_withdrawn_events: account::new_event_handle<CollateralWithdrawnEvent>(owner),
            usdc_borrowed_events: account::new_event_handle<UsdcBorrowedEvent>(owner),
            usdc_repaid_events: account::new_event_handle<UsdcRepaidEvent>(owner),
            usdc_lent_events: account::new_event_handle<UsdcLentEvent>(owner),
            usdc_withdrawn_from_lending_events: account::new_event_handle<UsdcWithdrawnFromLendingEvent>(owner),
            apt_rewards_claimed_events: account::new_event_handle<AptRewardsClaimedEvent>(owner),
            liquidated_events: account::new_event_handle<LiquidatedEvent>(owner),
            rates_updated_events: account::new_event_handle<RatesUpdatedEvent>(owner),
            protocol_fees_collected_events: account::new_event_handle<ProtocolFeesCollectedEvent>(owner),
        };
        
        move_to(owner, global_state);
    }
    
    // Update APT/USD price (owner only)
    public entry fun update_apt_price(
        owner: &signer,
        new_price: u64,
    ) acquires GlobalState {
        let global_state = borrow_global_mut<GlobalState>(@omni_lending);
        assert!(signer::address_of(owner) == global_state.owner, error::permission_denied(E_NOT_AUTHORIZED));
        
        global_state.price_feed.apt_usd_price = new_price;
        global_state.price_feed.last_updated = timestamp::now_seconds();
    }
    
    // Get current APT/USD price - internal function that takes price feed data
   fun get_apt_price_internal(price_feed: &PriceFeedData): u64 {
    let current_time = timestamp::now_seconds();
    assert!(
        current_time - price_feed.last_updated <= PRICE_FEED_STALENESS_THRESHOLD,
        error::invalid_state(E_PRICE_TOO_STALE)
    );
    assert!(price_feed.apt_usd_price > 0, error::invalid_state(E_INVALID_PRICE));

    // Convert 8 decimals → 18 decimals
    price_feed.apt_usd_price * 10000000000
}

    // Get current APT/USD price - public function that acquires global state
    public fun get_apt_price(): u64 acquires GlobalState {
        let global_state = borrow_global<GlobalState>(@omni_lending);
        get_apt_price_internal(&global_state.price_feed)
    }
    
    // Deposit APT as collateral
    public entry fun deposit_collateral(
        user: &signer,
        apt_amount: u64,
    ) acquires GlobalState {
        let global_state = borrow_global_mut<GlobalState>(@omni_lending);
        assert!(!global_state.paused, error::invalid_state(E_PROTOCOL_PAUSED));
        assert!(apt_amount >= global_state.min_collateral_amount, error::invalid_argument(E_INVALID_AMOUNT));
        
        let user_addr = signer::address_of(user);
        update_user_interest_internal(user_addr, global_state);
        
        let apt_coin = coin::withdraw<AptosCoin>(user, apt_amount);
        coin::merge(&mut global_state.apt_rewards_pool, apt_coin);
        
        if (!table::contains(&global_state.user_accounts, user_addr)) {
            table::add(&mut global_state.user_accounts, user_addr, UserAccount {
                apt_collateral: 0,
                usdc_borrowed: 0,
                usdc_lent: 0,
                last_borrow_update: timestamp::now_seconds(),
                last_lend_update: timestamp::now_seconds(),
                accrued_borrow_interest: 0,
                accrued_lend_rewards: 0,
            });
        };
        
        let user_account = table::borrow_mut(&mut global_state.user_accounts, user_addr);
        user_account.apt_collateral = user_account.apt_collateral + apt_amount;
        global_state.protocol_state.total_apt_collateral = global_state.protocol_state.total_apt_collateral + apt_amount;
        
        event::emit_event(
            &mut global_state.collateral_deposited_events,
            CollateralDepositedEvent {
                user: user_addr,
                apt_amount,
                timestamp: timestamp::now_seconds(),
            }
        );
    }
    
    // Withdraw APT collateral
  public entry fun withdraw_collateral(user: &signer, apt_amount: u64) acquires GlobalState {
    let global_state = borrow_global_mut<GlobalState>(@omni_lending);
    assert!(!global_state.paused, error::invalid_state(E_PROTOCOL_PAUSED));

    let user_addr = signer::address_of(user);
    assert!(
        table::contains(&global_state.user_accounts, user_addr),
        error::not_found(E_NO_COLLATERAL)
    );

    update_user_interest_internal(user_addr, global_state);

    // ✅ Fetch apt_price ONCE
    let apt_price = get_apt_price_internal(&global_state.price_feed);

    let user_account = table::borrow_mut(&mut global_state.user_accounts, user_addr);
    assert!(user_account.apt_collateral >= apt_amount, error::invalid_argument(E_INSUFFICIENT_COLLATERAL));

    let remaining_collateral = user_account.apt_collateral - apt_amount;

    if (user_account.usdc_borrowed > 0) {
        let current_borrowed = user_account.usdc_borrowed;
        let current_interest = user_account.accrued_borrow_interest;

        // ✅ Uses apt_price now
        let max_borrow = calculate_max_borrow_internal(remaining_collateral, apt_price);
        assert!(current_borrowed + current_interest <= max_borrow, error::invalid_state(E_INSUFFICIENT_COLLATERAL));
    };

    user_account.apt_collateral = remaining_collateral;
    global_state.protocol_state.total_apt_collateral = global_state.protocol_state.total_apt_collateral - apt_amount;

    let apt_coin = coin::extract(&mut global_state.apt_rewards_pool, apt_amount);
    coin::deposit(user_addr, apt_coin);

    event::emit_event(
        &mut global_state.collateral_withdrawn_events,
        CollateralWithdrawnEvent { user: user_addr, apt_amount, timestamp: timestamp::now_seconds() }
    );
}

 public entry fun borrow_usdc(user: &signer, usdc_amount: u64) acquires GlobalState {
    let global_state = borrow_global_mut<GlobalState>(@omni_lending);
    assert!(!global_state.paused, error::invalid_state(E_PROTOCOL_PAUSED));
    assert!(usdc_amount > 0, error::invalid_argument(E_INVALID_AMOUNT));

    let user_addr = signer::address_of(user);
    assert!(table::contains(&global_state.user_accounts, user_addr), error::not_found(E_NO_COLLATERAL));

    update_user_interest_internal(user_addr, global_state);
    update_rates_internal(global_state);

    // ✅ Fetch apt_price ONCE
    let apt_price = get_apt_price_internal(&global_state.price_feed);

    let user_account = table::borrow_mut(&mut global_state.user_accounts, user_addr);
    assert!(user_account.apt_collateral > 0, error::invalid_state(E_NO_COLLATERAL));

    let collateral_amount = user_account.apt_collateral;
    let current_borrowed = user_account.usdc_borrowed;
    let current_interest = user_account.accrued_borrow_interest;

    // ✅ Uses apt_price
    let max_borrow = calculate_max_borrow_internal(collateral_amount, apt_price);
    let total_debt = current_borrowed + current_interest + usdc_amount;

    assert!(total_debt <= max_borrow, error::invalid_state(E_EXCEEDS_COLLATERAL_CAPACITY));
    assert!(coin::value(&global_state.usdc_pool) >= usdc_amount, error::invalid_state(E_INSUFFICIENT_LIQUIDITY));

    user_account.usdc_borrowed = user_account.usdc_borrowed + usdc_amount;
    user_account.last_borrow_update = timestamp::now_seconds();
    global_state.protocol_state.total_usdc_borrowed = global_state.protocol_state.total_usdc_borrowed + usdc_amount;

    let usdc_coin = coin::extract(&mut global_state.usdc_pool, usdc_amount);
    coin::deposit(user_addr, usdc_coin);

    event::emit_event(
        &mut global_state.usdc_borrowed_events,
        UsdcBorrowedEvent { user: user_addr, usdc_amount, timestamp: timestamp::now_seconds() }
    );
}
    
    // Repay USDC debt
    public entry fun repay_usdc(
        user: &signer,
        usdc_amount: u64,
    ) acquires GlobalState {
        let global_state = borrow_global_mut<GlobalState>(@omni_lending);
        assert!(!global_state.paused, error::invalid_state(E_PROTOCOL_PAUSED));
        
        let user_addr = signer::address_of(user);
        assert!(table::contains(&global_state.user_accounts, user_addr), error::not_found(E_NO_DEBT));
        
        update_user_interest_internal(user_addr, global_state);
        
        let user_account = table::borrow_mut(&mut global_state.user_accounts, user_addr);
        assert!(
            user_account.usdc_borrowed > 0 || user_account.accrued_borrow_interest > 0,
            error::invalid_state(E_NO_DEBT)
        );
        
        let total_debt = user_account.usdc_borrowed + user_account.accrued_borrow_interest;
        let repay_amount = if (usdc_amount > total_debt) { total_debt } else { usdc_amount };
        
        let usdc_coin = coin::withdraw<USDC>(user, repay_amount);
        coin::merge(&mut global_state.usdc_pool, usdc_coin);
        
        // Pay interest first, then principal
        let interest_paid = 0;
        if (user_account.accrued_borrow_interest > 0) {
            let interest_payment = if (repay_amount > user_account.accrued_borrow_interest) {
                user_account.accrued_borrow_interest
            } else {
                repay_amount
            };
            user_account.accrued_borrow_interest = user_account.accrued_borrow_interest - interest_payment;
            interest_paid = interest_payment;
            repay_amount = repay_amount - interest_payment;
        };
        
        if (repay_amount > 0) {
            user_account.usdc_borrowed = user_account.usdc_borrowed - repay_amount;
            global_state.protocol_state.total_usdc_borrowed = global_state.protocol_state.total_usdc_borrowed - repay_amount;
        };
        
        event::emit_event(
            &mut global_state.usdc_repaid_events,
            UsdcRepaidEvent {
                user: user_addr,
                usdc_amount: repay_amount,
                interest_paid,
                timestamp: timestamp::now_seconds(),
            }
        );
    }
    
    // Lend USDC to earn APT rewards
    public entry fun lend_usdc(
        user: &signer,
        usdc_amount: u64,
    ) acquires GlobalState {
        let global_state = borrow_global_mut<GlobalState>(@omni_lending);
        assert!(!global_state.paused, error::invalid_state(E_PROTOCOL_PAUSED));
        assert!(usdc_amount >= global_state.min_lend_amount, error::invalid_argument(E_INVALID_AMOUNT));
        
        let user_addr = signer::address_of(user);
        update_user_rewards_internal(user_addr, global_state);
        
        let usdc_coin = coin::withdraw<USDC>(user, usdc_amount);
        coin::merge(&mut global_state.usdc_pool, usdc_coin);
        
        if (!table::contains(&global_state.user_accounts, user_addr)) {
            table::add(&mut global_state.user_accounts, user_addr, UserAccount {
                apt_collateral: 0,
                usdc_borrowed: 0,
                usdc_lent: 0,
                last_borrow_update: timestamp::now_seconds(),
                last_lend_update: timestamp::now_seconds(),
                accrued_borrow_interest: 0,
                accrued_lend_rewards: 0,
            });
        };
        
        let user_account = table::borrow_mut(&mut global_state.user_accounts, user_addr);
        user_account.usdc_lent = user_account.usdc_lent + usdc_amount;
        user_account.last_lend_update = timestamp::now_seconds();
        global_state.protocol_state.total_usdc_lent = global_state.protocol_state.total_usdc_lent + usdc_amount;
        
        event::emit_event(
            &mut global_state.usdc_lent_events,
            UsdcLentEvent {
                user: user_addr,
                usdc_amount,
                timestamp: timestamp::now_seconds(),
            }
        );
    }
    
    // Withdraw lent USDC
    public entry fun withdraw_lent_usdc(
        user: &signer,
        usdc_amount: u64,
    ) acquires GlobalState {
        let global_state = borrow_global_mut<GlobalState>(@omni_lending);
        assert!(!global_state.paused, error::invalid_state(E_PROTOCOL_PAUSED));
        
        let user_addr = signer::address_of(user);
        assert!(table::contains(&global_state.user_accounts, user_addr), error::not_found(E_NO_LENDING));
        
        update_user_rewards_internal(user_addr, global_state);
        
        let user_account = table::borrow_mut(&mut global_state.user_accounts, user_addr);
        assert!(user_account.usdc_lent >= usdc_amount, error::invalid_argument(E_NO_LENDING));
        
        // Check if protocol has enough liquidity
        let available_liquidity = coin::value(&global_state.usdc_pool) - global_state.protocol_state.total_usdc_borrowed;
        assert!(available_liquidity >= usdc_amount, error::invalid_state(E_INSUFFICIENT_LIQUIDITY));
        
        user_account.usdc_lent = user_account.usdc_lent - usdc_amount;
        global_state.protocol_state.total_usdc_lent = global_state.protocol_state.total_usdc_lent - usdc_amount;
        
        let usdc_coin = coin::extract(&mut global_state.usdc_pool, usdc_amount);
        coin::deposit(user_addr, usdc_coin);
        
        event::emit_event(
            &mut global_state.usdc_withdrawn_from_lending_events,
            UsdcWithdrawnFromLendingEvent {
                user: user_addr,
                usdc_amount,
                timestamp: timestamp::now_seconds(),
            }
        );
    }
    
    // Claim APT rewards from lending
    public entry fun claim_apt_rewards(
        user: &signer,
    ) acquires GlobalState {
        let global_state = borrow_global_mut<GlobalState>(@omni_lending);
        assert!(!global_state.paused, error::invalid_state(E_PROTOCOL_PAUSED));
        
        let user_addr = signer::address_of(user);
        update_user_rewards_internal(user_addr, global_state);
        
        assert!(table::contains(&global_state.user_accounts, user_addr), error::not_found(E_INSUFFICIENT_REWARDS));
        
        let user_account = table::borrow_mut(&mut global_state.user_accounts, user_addr);
        let rewards = user_account.accrued_lend_rewards;
        assert!(rewards > 0, error::invalid_state(E_INSUFFICIENT_REWARDS));
        assert!(
            coin::value(&global_state.apt_rewards_pool) >= rewards,
            error::invalid_state(E_INSUFFICIENT_LIQUIDITY)
        );
        
        user_account.accrued_lend_rewards = 0;
        global_state.protocol_state.total_apt_rewards = global_state.protocol_state.total_apt_rewards - rewards;
        
        let apt_coin = coin::extract(&mut global_state.apt_rewards_pool, rewards);
        coin::deposit(user_addr, apt_coin);
        
        event::emit_event(
            &mut global_state.apt_rewards_claimed_events,
            AptRewardsClaimedEvent {
                user: user_addr,
                apt_amount: rewards,
                timestamp: timestamp::now_seconds(),
            }
        );
    }
    
  public entry fun liquidate(liquidator: &signer, borrower: address, usdc_amount: u64) acquires GlobalState {
    let global_state = borrow_global_mut<GlobalState>(@omni_lending);
    assert!(!global_state.paused, error::invalid_state(E_PROTOCOL_PAUSED));

    let liquidator_addr = signer::address_of(liquidator);
    assert!(borrower != liquidator_addr, error::invalid_argument(E_CANNOT_LIQUIDATE_SELF));
    assert!(table::contains(&global_state.user_accounts, borrower), error::not_found(E_NO_DEBT));

    update_user_interest_internal(borrower, global_state);

    // ✅ Fetch apt_price ONCE
    let apt_price = get_apt_price_internal(&global_state.price_feed);

    let user_account = table::borrow_mut(&mut global_state.user_accounts, borrower);
    let total_debt = user_account.usdc_borrowed + user_account.accrued_borrow_interest;
    assert!(total_debt > 0, error::invalid_state(E_NO_DEBT));

    let collateral_amount = user_account.apt_collateral;

    // ✅ Uses apt_price
    let collateral_value = get_collateral_value_usd_internal(collateral_amount, apt_price);
    let health_factor = (collateral_value * BASIS_POINTS) / total_debt;

    assert!(health_factor < LIQUIDATION_THRESHOLD * 100, error::invalid_state(E_POSITION_HEALTHY));

    // Seize APT
    let base_apt_amount = (usdc_amount * PRECISION) / apt_price;
    let bonus_apt_amount = (base_apt_amount * LIQUIDATION_BONUS) / 100;
    let total_apt_to_seize = base_apt_amount + bonus_apt_amount;

    assert!(collateral_amount >= total_apt_to_seize, error::invalid_argument(E_INSUFFICIENT_COLLATERAL));
    assert!(usdc_amount <= total_debt, error::invalid_argument(E_INVALID_AMOUNT));

    // Transfer USDC → protocol
    let usdc_coin = coin::withdraw<USDC>(liquidator, usdc_amount);
    coin::merge(&mut global_state.usdc_pool, usdc_coin);

    // Update borrower debt
    if (usdc_amount >= user_account.accrued_borrow_interest) {
        let principal_repay = usdc_amount - user_account.accrued_borrow_interest;
        user_account.accrued_borrow_interest = 0;
        user_account.usdc_borrowed = user_account.usdc_borrowed - principal_repay;
        global_state.protocol_state.total_usdc_borrowed = global_state.protocol_state.total_usdc_borrowed - principal_repay;
    } else {
        user_account.accrued_borrow_interest = user_account.accrued_borrow_interest - usdc_amount;
    };

    // Transfer APT → liquidator
    user_account.apt_collateral = user_account.apt_collateral - total_apt_to_seize;
    global_state.protocol_state.total_apt_collateral = global_state.protocol_state.total_apt_collateral - total_apt_to_seize;

    let apt_coin = coin::extract(&mut global_state.apt_rewards_pool, total_apt_to_seize);
    coin::deposit(liquidator_addr, apt_coin);

    event::emit_event(
        &mut global_state.liquidated_events,
        LiquidatedEvent {
            borrower,
            liquidator: liquidator_addr,
            apt_seized: total_apt_to_seize,
            usdc_repaid: usdc_amount,
            timestamp: timestamp::now_seconds()
        }
    );
}
    // Calculate maximum borrow amount (internal version)
 fun calculate_max_borrow_internal(apt_amount: u64, apt_price: u64): u64 {
    let collateral_value_usd = get_collateral_value_usd_internal(apt_amount, apt_price);
    (collateral_value_usd * 100) / COLLATERAL_RATIO
}
    
    // Calculate maximum borrow amount (public version)
 fun calculate_max_borrow(apt_amount: u64): u64 acquires GlobalState {
    let global_state = borrow_global<GlobalState>(@omni_lending);
    let apt_price = get_apt_price_internal(&global_state.price_feed);
    calculate_max_borrow_internal(apt_amount, apt_price)
}

   fun get_collateral_value_usd_internal(apt_amount: u64, apt_price: u64): u64 {
    (apt_amount * apt_price) / PRECISION
}

    
    fun get_collateral_value_usd(apt_amount: u64): u64 acquires GlobalState {
        let global_state = borrow_global<GlobalState>(@omni_lending);
        let apt_price = get_apt_price_internal(&global_state.price_feed);

        get_collateral_value_usd_internal(apt_amount, apt_price)

    }

    fun update_user_interest_internal(user_addr: address, global_state: &mut GlobalState) {
        if (!table::contains(&global_state.user_accounts, user_addr)) {
            return
        };
        
        let user_account = table::borrow_mut(&mut global_state.user_accounts, user_addr);
        if (user_account.usdc_borrowed == 0) {
            return
        };
        
        let current_time = timestamp::now_seconds();
        let time_elapsed = current_time - user_account.last_borrow_update;
        if (time_elapsed == 0) {
            return
        };
        
        let interest = (user_account.usdc_borrowed * global_state.protocol_state.borrow_rate * time_elapsed) / 
                      (BASIS_POINTS * SECONDS_PER_YEAR);
        
        user_account.accrued_borrow_interest = user_account.accrued_borrow_interest + interest;
        user_account.last_borrow_update = current_time;
    }
    
    
    // Update user's borrow interest
       fun update_user_interest(user_addr: address) acquires GlobalState {
        let global_state = borrow_global_mut<GlobalState>(@omni_lending);
        update_user_interest_internal(user_addr, global_state);
    } 

 fun update_user_rewards_internal(user_addr: address, global_state: &mut GlobalState) {
    if (!table::contains(&global_state.user_accounts, user_addr)) return;

    let user_account = table::borrow_mut(&mut global_state.user_accounts, user_addr);
    if (user_account.usdc_lent == 0) return;

    let current_time = timestamp::now_seconds();
    let time_elapsed = current_time - user_account.last_lend_update;
    if (time_elapsed == 0) return;

    let usdc_lent = user_account.usdc_lent;
    let lend_reward_rate = global_state.protocol_state.lend_reward_rate;

    // ✅ Fetch apt_price ONCE
    let apt_price = get_apt_price_internal(&global_state.price_feed);

    let reward_value_usd = (usdc_lent * lend_reward_rate * time_elapsed)
        / (BASIS_POINTS * SECONDS_PER_YEAR);

    let apt_reward = (reward_value_usd * PRECISION) / apt_price;

    user_account.accrued_lend_rewards = user_account.accrued_lend_rewards + apt_reward;
    user_account.last_lend_update = current_time;
    global_state.protocol_state.total_apt_rewards = global_state.protocol_state.total_apt_rewards + apt_reward;
}
    
    // Update user's lending rewards
      fun update_user_rewards(user_addr: address) acquires GlobalState {
        let global_state = borrow_global_mut<GlobalState>(@omni_lending);
        update_user_rewards_internal(user_addr, global_state);
    }

     fun update_rates_internal(global_state: &mut GlobalState) {
        let current_time = timestamp::now_seconds();
        
        if (current_time < global_state.protocol_state.last_rate_update + 3600) { // 1 hour
            return
        };
        
        let total_liquidity = coin::value(&global_state.usdc_pool);
        if (total_liquidity == 0) {
            return
        };
        
        let utilization = (global_state.protocol_state.total_usdc_borrowed * BASIS_POINTS) / total_liquidity;
        
        // Update borrow rate based on utilization
        global_state.protocol_state.borrow_rate = BASE_BORROW_RATE + 
            (utilization * RATE_SLOPE) / BASIS_POINTS;
        
        // Update lend reward rate (inverse relationship with utilization)
        global_state.protocol_state.lend_reward_rate = BASE_REWARD_RATE + 
            ((BASIS_POINTS - utilization) * RATE_SLOPE) / (2 * BASIS_POINTS);
        
        global_state.protocol_state.last_rate_update = current_time;
        
        event::emit_event(
            &mut global_state.rates_updated_events,
            RatesUpdatedEvent {
                borrow_rate: global_state.protocol_state.borrow_rate,
                lend_reward_rate: global_state.protocol_state.lend_reward_rate,
                timestamp: current_time,
            }
        );
    }
    
    
    // Update protocol interest and reward rates based on utilization
      fun update_rates() acquires GlobalState {
        let global_state = borrow_global_mut<GlobalState>(@omni_lending);
        update_rates_internal(global_state);
    }
    
    
   public fun get_user_account(user_addr: address): (u64, u64, u64, u64, u64, u64, u64) acquires GlobalState {
    let global_state = borrow_global<GlobalState>(@omni_lending);

    if (!table::contains(&global_state.user_accounts, user_addr)) {
        return (0, 0, 0, 0, 0, 0, 0)
    };

    let user_account = table::borrow(&global_state.user_accounts, user_addr);

    let apt_collateral = user_account.apt_collateral;
    let usdc_borrowed = user_account.usdc_borrowed;
    let usdc_lent = user_account.usdc_lent;
    let accrued_interest = user_account.accrued_borrow_interest;
    let accrued_rewards = user_account.accrued_lend_rewards;

    // ✅ Fetch apt_price
    let apt_price = get_apt_price_internal(&global_state.price_feed);

    let health_factor = if (usdc_borrowed + accrued_interest > 0) {
        let collateral_value = get_collateral_value_usd_internal(apt_collateral, apt_price);
        let total_debt = usdc_borrowed + accrued_interest;
        (collateral_value * BASIS_POINTS) / total_debt
    } else {
        18446744073709551615 // u64::MAX
    };

    let max_borrow = calculate_max_borrow_internal(apt_collateral, apt_price);

    (apt_collateral, usdc_borrowed, usdc_lent, accrued_interest, accrued_rewards, health_factor, max_borrow)
}

// --- Get protocol state now uses price_feed correctly ---
public fun get_protocol_state(): (u64, u64, u64, u64, u64, u64, u64) acquires GlobalState {
    let global_state = borrow_global<GlobalState>(@omni_lending);

    let total_apt_collateral = global_state.protocol_state.total_apt_collateral;
    let total_usdc_borrowed = global_state.protocol_state.total_usdc_borrowed;
    let total_usdc_lent = global_state.protocol_state.total_usdc_lent;
    let borrow_rate = global_state.protocol_state.borrow_rate;
    let lend_reward_rate = global_state.protocol_state.lend_reward_rate;

    let total_liquidity = coin::value(&global_state.usdc_pool);
    let utilization = if (total_liquidity > 0) {
        (global_state.protocol_state.total_usdc_borrowed * BASIS_POINTS) / total_liquidity
    } else {
        0
    };

    // ✅ Fixed
    let apt_price = get_apt_price_internal(&global_state.price_feed);

    (total_apt_collateral, total_usdc_borrowed, total_usdc_lent, borrow_rate, lend_reward_rate, utilization, apt_price)
}

    // Owner functions
    public entry fun pause(owner: &signer) acquires GlobalState {
        let global_state = borrow_global_mut<GlobalState>(@omni_lending);
        assert!(signer::address_of(owner) == global_state.owner, error::permission_denied(E_NOT_AUTHORIZED));
        global_state.paused = true;
    }
    
    public entry fun unpause(owner: &signer) acquires GlobalState {
        let global_state = borrow_global_mut<GlobalState>(@omni_lending);
        assert!(signer::address_of(owner) == global_state.owner, error::permission_denied(E_NOT_AUTHORIZED));
        global_state.paused = false;
    }
    
    public entry fun set_treasury(owner: &signer, new_treasury: address) acquires GlobalState {
        let global_state = borrow_global_mut<GlobalState>(@omni_lending);
        assert!(signer::address_of(owner) == global_state.owner, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(new_treasury != @0x0, error::invalid_argument(E_INVALID_ADDRESS));
        global_state.treasury = new_treasury;
    }
    
    public entry fun update_protocol_parameters(
        owner: &signer,
        protocol_fee: u64,
        min_collateral_amount: u64,
        min_lend_amount: u64,
    ) acquires GlobalState {
        let global_state = borrow_global_mut<GlobalState>(@omni_lending);
        assert!(signer::address_of(owner) == global_state.owner, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(protocol_fee <= 2000, error::invalid_argument(E_PROTOCOL_FEE_TOO_HIGH)); // Max 20%
        
        global_state.protocol_fee = protocol_fee;
        global_state.min_collateral_amount = min_collateral_amount;
        global_state.min_lend_amount = min_lend_amount;
    }
    
    // Collect protocol fees
    public entry fun collect_protocol_fees(owner: &signer) acquires GlobalState {
        let global_state = borrow_global_mut<GlobalState>(@omni_lending);
        assert!(signer::address_of(owner) == global_state.owner, error::permission_denied(E_NOT_AUTHORIZED));
        
        let usdc_balance = coin::value(&global_state.usdc_pool);
        let excess_usdc = usdc_balance - global_state.protocol_state.total_usdc_lent;
        
        let usdc_fee_amount = if (excess_usdc > 0) {
            let fee_amount = (excess_usdc * global_state.protocol_fee) / BASIS_POINTS;
            if (fee_amount > 0) {
                let usdc_fee = coin::extract(&mut global_state.usdc_pool, fee_amount);
                coin::deposit(global_state.treasury, usdc_fee);
                fee_amount
            } else {
                0
            }
        } else {
            0
        };
        
        let apt_balance = coin::value(&global_state.apt_rewards_pool);
        let excess_apt = apt_balance - global_state.protocol_state.total_apt_collateral - global_state.protocol_state.total_apt_rewards;
        
        let apt_fee_amount = if (excess_apt > 0) {
            let apt_fee = coin::extract(&mut global_state.apt_rewards_pool, excess_apt);
            coin::deposit(global_state.treasury, apt_fee);
            excess_apt
        } else {
            0
        };
        
        event::emit_event(
            &mut global_state.protocol_fees_collected_events,
            ProtocolFeesCollectedEvent {
                usdc_amount: usdc_fee_amount,
                apt_amount: apt_fee_amount,
                timestamp: timestamp::now_seconds(),
            }
        );
    }
    
    // Emergency withdrawal (only owner)
    public entry fun emergency_withdraw_usdc(
        owner: &signer,
        amount: u64,
    ) acquires GlobalState {
        let global_state = borrow_global_mut<GlobalState>(@omni_lending);
        assert!(signer::address_of(owner) == global_state.owner, error::permission_denied(E_NOT_AUTHORIZED));
        
        let usdc_coin = coin::extract(&mut global_state.usdc_pool, amount);
        coin::deposit(signer::address_of(owner), usdc_coin);
    }
    
    public entry fun emergency_withdraw_apt(
        owner: &signer,
        amount: u64,
    ) acquires GlobalState {
        let global_state = borrow_global_mut<GlobalState>(@omni_lending);
        assert!(signer::address_of(owner) == global_state.owner, error::permission_denied(E_NOT_AUTHORIZED));
        
        let apt_coin = coin::extract(&mut global_state.apt_rewards_pool, amount);
        coin::deposit(signer::address_of(owner), apt_coin);
    }
    
    // Add APT to rewards pool (anyone can contribute)
    public entry fun add_apt_rewards(
        contributor: &signer,
        apt_amount: u64,
    ) acquires GlobalState {
        let global_state = borrow_global_mut<GlobalState>(@omni_lending);
        
        let apt_coin = coin::withdraw<AptosCoin>(contributor, apt_amount);
        coin::merge(&mut global_state.apt_rewards_pool, apt_coin);
    }
    
    // View functions
    public fun is_paused(): bool acquires GlobalState {
        let global_state = borrow_global<GlobalState>(@omni_lending);
        global_state.paused
    }
    
    public fun get_owner(): address acquires GlobalState {
        let global_state = borrow_global<GlobalState>(@omni_lending);
        global_state.owner
    }
    
    public fun get_treasury(): address acquires GlobalState {
        let global_state = borrow_global<GlobalState>(@omni_lending);
        global_state.treasury
    }
    
    public fun get_protocol_parameters(): (u64, u64, u64) acquires GlobalState {
        let global_state = borrow_global<GlobalState>(@omni_lending);
        (global_state.protocol_fee, global_state.min_collateral_amount, global_state.min_lend_amount)
    }
    
    public fun get_pool_balances(): (u64, u64) acquires GlobalState {
        let global_state = borrow_global<GlobalState>(@omni_lending);
        (coin::value(&global_state.usdc_pool), coin::value(&global_state.apt_rewards_pool))
    }
    
    // Test helper functions (only for testnet)
    #[test_only]
    public fun init_for_test(
        owner: &signer,
        treasury: address,
        initial_apt_usd_price: u64,
    ) {
        initialize(owner, treasury, initial_apt_usd_price);
    }
    
    #[test_only]
    public fun get_user_account_for_test(user_addr: address): UserAccount acquires GlobalState {
        let global_state = borrow_global<GlobalState>(@omni_lending);
        *table::borrow(&global_state.user_accounts, user_addr)
    }
}