#[test_only]
module techgnosis::elegbara_router_tests {
    use techgnosis::elegbara_router::{Self as router, ElegbaraRouter, BirthRecord};
    use sui::coin;
    use sui::test_scenario as ts;
    use sui::transfer;

    // A stand-in stablecoin type for the test (in production T = USDC).
    public struct FAKEUSD has drop {}

    #[test]
    fun test_esu_tithe_and_net() {
        let admin = @0xA;
        let mut sc = ts::begin(admin);

        // 1. create + share the router for FAKEUSD
        router::create_router<FAKEUSD>(ts::ctx(&mut sc));
        ts::next_tx(&mut sc, admin);

        let mut r = ts::take_shared<ElegbaraRouter<FAKEUSD>>(&sc);

        // 2. settle a 1000-unit payment through the router
        let payment = coin::mint_for_testing<FAKEUSD>(1000, ts::ctx(&mut sc));
        let net = router::route_transaction_tax<FAKEUSD>(&mut r, payment, ts::ctx(&mut sc));

        // 3. assert: 3.69% of 1000 = 36 (integer floor); net returned = 964
        assert!(coin::value(&net) == 964, 100);
        assert!(router::total_esu_tax(&r) == 36, 101);
        // tithe routed: 30% of 36 = 10 to VeilSim
        assert!(router::veilsim_balance(&r) == 10, 102);

        coin::burn_for_testing(net);
        ts::return_shared(r);
        ts::end(sc);
    }

    #[test]
    fun test_extract_pure() {
        let (tax, net) = router::extract_esu_tax(1_000_000);
        assert!(tax == 36_900, 200);   // 3.69% of 1e6
        assert!(net == 963_100, 201);
    }

    #[test]
    fun test_royalty_bps_for_generation() {
        assert!(router::royalty_bps_for_generation(0) == 2000, 300);
        assert!(router::royalty_bps_for_generation(1) == 1500, 301);
        assert!(router::royalty_bps_for_generation(2) == 1000, 302);
        assert!(router::royalty_bps_for_generation(99) == 1000, 303);
    }

    #[test]
    fun test_process_agent_birth_returns_birth_record() {
        let admin = @0xA;
        let agent_addr = @0xB;
        let birther_addr = @0xC;
        let mut sc = ts::begin(admin);

        router::create_router<FAKEUSD>(ts::ctx(&mut sc));
        ts::next_tx(&mut sc, admin);

        let mut r = ts::take_shared<ElegbaraRouter<FAKEUSD>>(&sc);
        let fee = coin::mint_for_testing<FAKEUSD>(1000, ts::ctx(&mut sc));

        let record = router::process_agent_birth<FAKEUSD>(
            &mut r, fee, agent_addr, birther_addr, 0, ts::ctx(&mut sc)
        );

        // BirthRecord fields
        assert!(router::birth_record_agent_addr(&record) == agent_addr, 400);
        assert!(router::birth_record_birther_addr(&record) == birther_addr, 401);
        assert!(router::birth_record_royalty_bps(&record) == 2000, 402); // gen 0
        assert!(router::birth_record_generation(&record) == 0, 403);
        assert!(router::total_agents_born(&r) == 1, 404);

        transfer::public_transfer(record, admin);
        ts::return_shared(r);
        ts::end(sc);
    }

    #[test]
    fun test_settle_job_payment() {
        let admin = @0xA;
        let agent_addr = @0xB;
        let birther_addr = @0xC;
        let mut sc = ts::begin(admin);

        router::create_router<FAKEUSD>(ts::ctx(&mut sc));
        ts::next_tx(&mut sc, admin);

        let mut r = ts::take_shared<ElegbaraRouter<FAKEUSD>>(&sc);

        // Create a BirthRecord (gen 0, royalty_bps = 2000)
        let fee = coin::mint_for_testing<FAKEUSD>(1000, ts::ctx(&mut sc));
        let record = router::process_agent_birth<FAKEUSD>(
            &mut r, fee, agent_addr, birther_addr, 0, ts::ctx(&mut sc)
        );

        // Gross payment = 10_000
        let payment = coin::mint_for_testing<FAKEUSD>(10_000, ts::ctx(&mut sc));
        let (birther_coin, agent_coin) = router::settle_job_payment<FAKEUSD>(
            &mut r, &record, payment, ts::ctx(&mut sc)
        );

        // Step 1: esu_tax = floor(10_000 * 369 / 10_000) = 369
        // net = 10_000 - 369 = 9_631
        // Step 2: birther = floor(9_631 * 2000 / 10_000) = 1926
        //         agent   = floor(9_631 * 1500 / 10_000) = 1444
        //         ecosystem = 9_631 - 1926 - 1444 = 6261
        assert!(coin::value(&birther_coin) == 1926, 500);
        assert!(coin::value(&agent_coin) == 1444, 501);

        coin::burn_for_testing(birther_coin);
        coin::burn_for_testing(agent_coin);
        transfer::public_transfer(record, admin);
        ts::return_shared(r);
        ts::end(sc);
    }
}
