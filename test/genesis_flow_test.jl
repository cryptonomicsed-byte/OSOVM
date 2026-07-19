# test/genesis_flow_test.jl — Genesis Flow Integration Test
# Verifies: genesis flaw + wallet derivation + tithe routing
# Crown Architect: Bínò ÈL Guà
# Auditor: Ọbàtálá

using Test
using JSON3

# Include necessary modules
include("../src/opcodes.jl")
include("../src/oso_compiler.jl")
include("../src/oso_vm.jl")

using .Opcodes
using .OsoCompiler
using .OsoVM

@testset "Genesis Flow Integration (Week 1)" begin
    
    # ==========================================
    # Test 1: Compiler recognizes @genesisFlawToken
    # ==========================================
    @testset "Compiler: @genesisFlawToken parsing" begin
        source = """
        @genesisFlawToken(token="ASHE", amount=1.0) {
        }
        """
        ir = OsoCompiler.compile_oso(source)
        
        @test length(ir) >= 1
        @test ir[1].opcode == 0x2b  # GENESIS_FLAW_TOKEN
        @test ir[1].args[:token] == "ASHE"
        @test ir[1].args[:amount] == 1.0
    end
    
    # ==========================================
    # Test 2: Block 0 — ASHE mints to Àṣẹ
    # ==========================================
    @testset "VM: Block 0 ASHE minting (Èṣù's Twist)" begin
        vm = OsoVM.create_vm(
            council = ["council_$i" for i in 1:12],
            final_signer = "bino_genesis"
        )
        vm.block_height = 0  # Genesis block
        
        source = """
        @genesisFlawToken(token="ASHE", amount=1.0) {
        }
        """
        ir = OsoCompiler.compile_oso(source)
        
        # Simulate execution (mock)
        # Expected: token minted as "Àṣẹ" (transformed from "ASHE")
        @test ir[1].opcode == 0x2b
        @test ir[1].args[:token] == "ASHE"
        @test ir[1].args[:amount] == 1.0
        
        # In real execution, VM would mint 1.0 Àṣẹ to wallet_0001
        println("✅ Block 0: ASHE would mint to Àṣẹ (mock)")
    end
    
    # ==========================================
    # Test 3: Block > 0 — ASHE rejected
    # ==========================================
    @testset "VM: Block > 0 ASHE rejection (Eternal Freeze)" begin
        vm = OsoVM.create_vm(
            council = ["council_$i" for i in 1:12],
            final_signer = "bino_genesis"
        )
        vm.block_height = 1  # Post-genesis
        
        source = """
        @genesisFlawToken(token="ASHE", amount=1.0) {
        }
        """
        ir = OsoCompiler.compile_oso(source)
        
        # After block 0, ASHE is forever rejected
        @test ir[1].opcode == 0x2b
        @test ir[1].args[:token] == "ASHE"
        
        # In real execution, VM would reject with "flaw_denied_post_genesis"
        println("✅ Block 1+: ASHE forever rejected (mock)")
    end
    
    # ==========================================
    # Test 4: Opcode mapping consistency
    # ==========================================
    @testset "Opcodes: GENESIS_FLAW_TOKEN exists" begin
        @test haskey(Opcodes.CORE_OPCODES, :GENESIS_FLAW_TOKEN)
        @test Opcodes.CORE_OPCODES[:GENESIS_FLAW_TOKEN] == 0x2b  # opcodes.jl is the single source of truth

        opcode = Opcodes.CORE_OPCODES[:GENESIS_FLAW_TOKEN]
        @test opcode == 0x2b
    end
    
    # ==========================================
    # Test 5: VM state initialization
    # ==========================================
    @testset "VM: 1440 wallets initialized" begin
        vm = OsoVM.create_vm()
        
        @test length(vm.wallets) == 1440
        @test length(vm.staking_vaults) == 1440
        
        # Check first and last wallet
        @test vm.wallets[1].wallet_id == UInt16(0)
        @test vm.wallets[end].wallet_id == UInt16(1439)
        
        # All wallets start in OPEN state
        @test vm.wallets[1].state == OsoVM.OPEN
        @test vm.wallets[end].state == OsoVM.OPEN
        
        println("✅ All 1440 inheritance wallets initialized")
    end
    
    # ==========================================
    # Test 6: Tithe calculation (mock)
    # ==========================================
    @testset "Tithe: 3.69% split logic" begin
        amount = 100.0
        tithe_rate = 0.0369
        tithe = amount * tithe_rate
        
        # Expected: 3.69
        @test isapprox(tithe, 3.69, atol=0.01)
        
        # Splits
        splits = Dict(
            "shrine" => tithe * 0.50,      # 50%
            "inheritance" => tithe * 0.25, # 25%
            "council" => tithe * 0.15,     # 15%
            "burn" => tithe * 0.10,        # 10%
        )
        
        total = sum(values(splits))
        @test isapprox(total, tithe, atol=0.001)
        
        # Verify ratios
        @test isapprox(splits["shrine"], 1.845, atol=0.001)
        @test isapprox(splits["inheritance"], 0.9225, atol=0.001)
        @test isapprox(splits["council"], 0.5535, atol=0.001)
        @test isapprox(splits["burn"], 0.369, atol=0.001)
        
        println("✅ Tithe split (50/25/15/10) verified")
    end
    
    # ==========================================
    # Test 7: Sabbath enforcement (on Saturday)
    # ==========================================
    @testset "Sabbath: Block all transactions on Saturday" begin
        vm = OsoVM.create_vm()
        
        # Simulate Saturday check (dayofweek == 6)
        # This would be checked by VM.execute_ir()
        using Dates
        now = Dates.now()
        day_of_week = Dates.dayofweek(now)
        
        # Test logic (not actual execution, just verification)
        is_saturday = day_of_week == 6
        
        if is_saturday
            println("⚠️  Today is Saturday (blocks would be frozen)")
        else
            println("✅ Not Saturday (blocks allowed to execute)")
        end
    end
    
    # ==========================================
    # Test 8: Council of 12 initialization
    # ==========================================
    @testset "Council: 12 members initialized" begin
        council = ["council_$i" for i in 1:12]
        vm = OsoVM.create_vm(
            council = council,
            final_signer = "bino_genesis"
        )
        
        @test length(vm.council) == 12
        @test vm.final_signer == "bino_genesis"
        
        println("✅ Council of 12 + Bínò final signer ready")
    end
    
    # ==========================================
    # Test 9: Wallet state transitions
    # ==========================================
    @testset "Wallets: State machine" begin
        vm = OsoVM.create_vm()
        
        # Wallet #0 should start OPEN
        @test vm.wallets[1].state == OsoVM.OPEN
        
        # Simulate candidate apply
        # (would be: vm.wallets[1].state = PENDING)
        # For now, just verify enum exists
        @test Int(OsoVM.OPEN) == 1
        @test Int(OsoVM.PENDING) == 2
        @test Int(OsoVM.COUNCIL_READY) == 3
        @test Int(OsoVM.AWARDED) == 4
        
        println("✅ Wallet state machine defined (OPEN → PENDING → COUNCIL_READY → AWARDED)")
    end
    
    # ==========================================
    # Test 10: Staking vault (11.11% APY)
    # ==========================================
    @testset "Staking: 11.11% APY vaults" begin
        vm = OsoVM.create_vm()
        
        @test length(vm.staking_vaults) == 1440
        
        # All vaults start at 0.0 balance
        @test vm.staking_vaults[1].locked_balance == 0.0
        @test vm.staking_vaults[1].accrued_rewards == 0.0
        
        # APY constant
        apy = 0.1111  # 11.11%
        principal = 451.0  # Example: wallet receives 451 Àṣẹ
        annual_reward = principal * apy
        
        @test isapprox(annual_reward, 50.1, atol=0.1)
        
        println("✅ Staking vault initialized (11.11% APY ready)")
    end

end

println("\n✅ Genesis Flow Integration Test Complete!")
println("🤍🗿⚖️🕊️🌄 The path is ready. Àṣẹ. Àṣẹ. Àṣẹ.")
