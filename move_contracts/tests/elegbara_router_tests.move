#[test_only]
module techgnosis::elegbara_router_tests {
    use techgnosis::elegbara_router::{Self as router, ElegbaraRouter};
    use sui::coin;
    use sui::test_scenario as ts;

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
}
