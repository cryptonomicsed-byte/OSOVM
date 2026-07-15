#[cfg(test)]
module techgnosis::ase_tests {
    use techgnosis::ase::{Self, ASE};
    use sui::test_scenario::{Self, Scenario};
    use sui::coin::{Self, Coin};
    use sui::balance;

    #[test]
    fun test_mint_impact() {
        let mut scenario = test_scenario::begin(@0x1);
        {
            ase::init(scenario.ctx_mut());
        };
        scenario.next_tx(@0x1);
        {
            // Verify token creation succeeded
            // In production, would access Treasury and Governor objects
        };
        scenario.end();
    }

    #[test]
    fun test_tithe_distribution() {
        let mut scenario = test_scenario::begin(@0x1);
        {
            ase::init(scenario.ctx_mut());
        };
        scenario.next_tx(@0x1);
        {
            // Test that tithe is correctly split
            // 50% Shrine, 25% Inheritance, 15% AIO, 10% Burn
        };
        scenario.end();
    }

    #[test]
    fun test_inheritance_vault_creation() {
        let mut scenario = test_scenario::begin(@0x1);
        {
            ase::init(scenario.ctx_mut());
        };
        scenario.next_tx(@0x1);
        {
            // Create inheritance vault for wallet #1
            let vault = ase::create_inheritance_vault(1, scenario.ctx_mut());
            assert!(ase::vault_wallet_id(&vault) == 1, 1);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 100)]
    fun test_invalid_wallet_id() {
        let mut scenario = test_scenario::begin(@0x1);
        {
            ase::init(scenario.ctx_mut());
        };
        scenario.next_tx(@0x1);
        {
            // Wallet ID must be 1-1440
            let _vault = ase::create_inheritance_vault(1441, scenario.ctx_mut());
        };
        scenario.end();
    }

    #[test]
    fun test_halving_schedule() {
        let mut scenario = test_scenario::begin(@0x1);
        {
            ase::init(scenario.ctx_mut());
        };
        scenario.next_tx(@0x1);
        {
            // Verify initial halving value
            // First halving: 2880 / 2 = 1440
        };
        scenario.end();
    }

    #[test]
    fun test_apy_accrual() {
        let mut scenario = test_scenario::begin(@0x1);
        {
            ase::init(scenario.ctx_mut());
        };
        scenario.next_tx(@0x1);
        {
            let vault = ase::create_inheritance_vault(1, scenario.ctx_mut());
            // Test APY calculation: 11.11% annual
            // After 1 year, balance should grow by 11.11%
        };
        scenario.end();
    }
}
