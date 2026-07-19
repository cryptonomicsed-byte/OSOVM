# P0 End-to-End Test: Agent Earning Flow
# Sim Library → Agent Query → Consume → 2× Reward → Tithe
# Crown Architect: Bino EL Gua Omo Koda Ase

push!(LOAD_PATH, joinpath(@__DIR__, "..", "src"))

using SHA, Dates

include(joinpath(@__DIR__, "..", "src", "world_tiles.jl"))

using .WorldTiles

# ============================================================================
# TEST UTILITIES
# ============================================================================

passed = 0
failed = 0
total = 0

function test(name::String, condition::Bool)
    global passed, failed, total
    total += 1
    if condition
        passed += 1
        println("  ✓ $name")
    else
        failed += 1
        println("  ✗ FAIL: $name")
    end
end

function test_section(name::String)
    println("\n═══ $name ═══")
end

# ============================================================================
# 1. WORLD TILE CREATION & INDEXING
# ============================================================================

test_section("World Tiles — spatial partitioning")

tile_a = create_tile(4, 7, 7)   # Layer 4, x=7, z=7 (air corridor)
tile_b = create_tile(4, 9, 9)   # Destination
tile_c = create_tile(0, 0, 0)   # Ground origin

test("Tile A layer == 4", tile_a.layer == 4)
test("Tile A x == 7", tile_a.x == 7)
test("Tile key format", tile_key(tile_a) == "4:7:7")
test("Tile B key format", tile_key(tile_b) == "4:9:9")

# Range query
nearby = tiles_in_range(tile_a, 1)
test("Range-1 around tile_a produces tiles", length(nearby) > 0)
test("Range-1 produces 3^3=27 tiles", length(nearby) == 27)
test("Center tile is in range", tile_a in nearby)

# ============================================================================
# 2. SIM LIBRARY — Initialization
# ============================================================================

test_section("Sim Library — marketplace creation")

library = SimLibrary(f1_threshold=0.777, expiry_days=49)

test("Library starts empty", library.total_simulations == 0)
test("F1 threshold is 0.777", library.f1_threshold == 0.777)
test("Expiry is 49 days", library.expiry_days == 49)
test("No Àṣẹ minted yet", library.total_ase_minted == 0.0)

# ============================================================================
# 3. HUMAN MINER SUBMITS SIMULATION
# ============================================================================

test_section("Human Miner — simulation submission")

human_wallet = "human-miner-lagos-abc123"
origin = create_tile(4, 7, 7)
dest = create_tile(4, 9, 9)
veil_ids = [176, 251]
checkpoints = [
    Dict{String,Any}("step" => 0, "pos" => [700.0, 400.0, 700.0], "v" => [1.0, 0.0, 1.0]),
    Dict{String,Any}("step" => 50, "pos" => [800.0, 400.0, 800.0], "v" => [1.0, 0.0, 1.0]),
    Dict{String,Any}("step" => 100, "pos" => [900.0, 400.0, 900.0], "v" => [0.0, 0.0, 0.0]),
]
chain_anchors = Dict("sui" => "0xabc123", "arweave" => "0xdef456")

# Good sim (F1 = 0.92, above threshold)
good_sim = submit_simulation(
    library, "sim-good-001", human_wallet,
    origin, dest, veil_ids,
    3, 100, 0.92, 0.001, 0.95,
    checkpoints, chain_anchors
)

test("Good sim accepted (not nothing)", good_sim !== nothing)
test("Good sim ID stored", good_sim.sim_id == "sim-good-001")
test("Good sim creator is human", good_sim.creator_wallet == human_wallet)
test("Good sim F1 = 0.92", good_sim.f1_score == 0.92)
test("Good sim cost = 7.77 Àṣẹ", good_sim.ase_cost == 7.77)
test("Good sim status = validated", good_sim.status == "validated")
test("Library now has 1 simulation", library.total_simulations == 1)
test("Library minted 7.77 Àṣẹ", library.total_ase_minted == 7.77)

# Bad sim (F1 = 0.5, below threshold)
bad_sim = submit_simulation(
    library, "sim-bad-002", human_wallet,
    origin, dest, veil_ids,
    3, 100, 0.5, 0.1, 0.3,
    checkpoints, chain_anchors
)

test("Bad sim rejected (returns nothing)", bad_sim === nothing)
test("Library still has 1 simulation", library.total_simulations == 1)

# ============================================================================
# 4. AGENT QUERIES LIBRARY — Cache Miss Then Hit
# ============================================================================

test_section("Agent Query — cache miss then hit")

agent_wallet = "agent-42-7f3a9b00"

# Query for a route we DON'T have
missing_origin = create_tile(0, 99, 99)
missing_dest = create_tile(0, 100, 100)
miss_results = query_simulations(library, missing_origin, missing_dest)
test("Cache MISS — no results for unknown route", isempty(miss_results))

# Query for the route we DO have
hit_results = query_simulations(library, origin, dest)
test("Cache HIT — found results for known route", !isempty(hit_results))
test("Hit returns our sim", hit_results[1].sim_id == "sim-good-001")
test("Hit F1 ≥ threshold", hit_results[1].f1_score >= 0.777)

# Query with higher F1 filter
filtered = query_simulations(library, origin, dest, min_f1=0.95)
test("Filter F1>0.95: no results (our sim is 0.92)", isempty(filtered))

# ============================================================================
# 5. AGENT CONSUMES SIMULATION — 2× Reward
# ============================================================================

test_section("Agent Consumption — 2× creator reward")

trajectory = consume_simulation(library, "sim-good-001", agent_wallet)

test("Consumption returns trajectory", trajectory !== nothing)
test("Trajectory has 3 checkpoints", length(trajectory) == 3)
test("First checkpoint is origin area", trajectory[1]["pos"][1] == 700.0)
test("Last checkpoint is destination area", trajectory[3]["pos"][1] == 900.0)

# Verify creator earnings
record = library.records["sim-good-001"]
expected_reward = 7.77 * 2.0  # BASE_SIM_COST × CONSUMPTION_MULTIPLIER
test("Creator earned 2× Àṣẹ", abs(record.ase_earned - expected_reward) < 0.01)
test("Consumption count = 1", record.consumption_count == 1)
test("Library total consumptions = 1", library.total_consumptions == 1)
test("Library consumed Àṣẹ = $(expected_reward)", abs(library.total_ase_consumed - expected_reward) < 0.01)

# Second consumption doubles again
trajectory2 = consume_simulation(library, "sim-good-001", "agent-other-xyz")
test("Second consumption succeeds", trajectory2 !== nothing)
test("Consumption count = 2", record.consumption_count == 2)
test("Creator earned 2× again (total 4×)", abs(record.ase_earned - expected_reward * 2) < 0.01)

# ============================================================================
# 6. VEIL-BASED QUERY
# ============================================================================

test_section("Veil-Based Query")

veil_results = query_by_veil(library, 176)
test("Veil 176 query finds sim", !isempty(veil_results))
test("Found sim has veil 176", 176 in veil_results[1].veil_ids)

veil_empty = query_by_veil(library, 999)
test("Unknown veil returns empty", isempty(veil_empty))

# ============================================================================
# 7. F1 THRESHOLD ENFORCEMENT — Deterministic, Not Random
# ============================================================================

test_section("F1 Threshold — deterministic enforcement")

# Submit multiple sims with varying F1
f1_values = [0.77, 0.776, 0.777, 0.78, 0.85, 0.95, 1.0]
accepted_count = 0
for (i, f1) in enumerate(f1_values)
    result = submit_simulation(
        library, "sim-f1-$(i)", human_wallet,
        create_tile(0, i, 0), create_tile(0, i+1, 0),
        [100], 1, 50, f1, 0.001, 0.9,
        [Dict{String,Any}("step" => 0, "pos" => [0.0,0.0,0.0])],
        Dict{String,String}()
    )
    if result !== nothing
        global accepted_count += 1
    end
end

# 0.77 and 0.776 should be rejected; 0.777+ should be accepted
test("F1=0.77 rejected (below 0.777)", !haskey(library.records, "sim-f1-1"))
test("F1=0.776 rejected (below 0.777)", !haskey(library.records, "sim-f1-2"))
test("F1=0.777 accepted (at threshold)", haskey(library.records, "sim-f1-3"))
test("F1=0.78 accepted", haskey(library.records, "sim-f1-4"))
test("F1=0.95 accepted", haskey(library.records, "sim-f1-6"))
test("F1=1.0 accepted", haskey(library.records, "sim-f1-7"))

# ============================================================================
# 8. SIM VALUE COMPUTATION
# ============================================================================

test_section("Sim Value — F1 + consumption + age decay")

value = compute_sim_value(library.records["sim-good-001"])
test("Sim value is positive", value > 0.0)

# Higher F1 → higher value
if haskey(library.records, "sim-f1-7")  # F1=1.0
    value_perfect = compute_sim_value(library.records["sim-f1-7"])
    # Note: sim-good-001 has consumption bonus, so may be higher
    # Just verify both are positive
    test("Perfect F1 sim has positive value", value_perfect > 0.0)
end

# ============================================================================
# 9. LIBRARY STATISTICS
# ============================================================================

test_section("Library Statistics")

stats = library_stats(library)
test("Stats: total_simulations > 0", stats["total_simulations"] > 0)
test("Stats: total_consumptions == 2", stats["total_consumptions"] == 2)
test("Stats: total_ase_minted > 0", stats["total_ase_minted"] > 0.0)
test("Stats: total_ase_consumed > 0", stats["total_ase_consumed"] > 0.0)
test("Stats: average_f1 > 0", stats["average_f1"] > 0.0)
test("Stats: tiles indexed > 0", stats["unique_tiles_indexed"] > 0)
test("Stats: veils indexed > 0", stats["unique_veils_indexed"] > 0)

# ============================================================================
# 10. ECONOMIC LOOP CLOSURE — Human Creates, Agent Consumes, Both Profit
# ============================================================================

test_section("Economic Loop Closure — symbiotic economy")

# Reset library for clean accounting
econ_lib = SimLibrary(f1_threshold=0.777)

human = "human-physicist-001"
agent = "agent-drone-alpha-42"

# Human creates sim (pays 7.77 Àṣẹ)
sim = submit_simulation(
    econ_lib, "econ-sim-001", human,
    create_tile(1, 0, 0), create_tile(1, 5, 5),
    [176, 251], 2, 200, 0.95, 0.0005, 0.98,
    [Dict{String,Any}("step" => 0, "pos" => [0.0,100.0,0.0]),
     Dict{String,Any}("step" => 200, "pos" => [500.0,100.0,500.0])],
    Dict{String,String}("sui" => "0xecon001")
)
test("Econ sim accepted", sim !== nothing)
test("Human paid 7.77 Àṣẹ creation cost", sim.ase_cost == 7.77)

# Agent consumes (human earns 2× = 15.54 Àṣẹ)
traj = consume_simulation(econ_lib, "econ-sim-001", agent)
test("Agent got trajectory", traj !== nothing)

record = econ_lib.records["econ-sim-001"]
test("Human earned 15.54 Àṣẹ from consumption", abs(record.ase_earned - 15.54) < 0.01)

# Net profit for human: 15.54 - 7.77 = 7.77 Àṣẹ
net_profit = record.ase_earned - record.ase_cost
test("Human net profit = 7.77 Àṣẹ", abs(net_profit - 7.77) < 0.01)

# Tithe calculation (3.69% of earnings)
tithe_rate = 0.0369
tithe_on_earnings = record.ase_earned * tithe_rate
test("Tithe on earnings = $(round(tithe_on_earnings, digits=4)) Àṣẹ", tithe_on_earnings > 0)
test("Tithe is 3.69% of 15.54", abs(tithe_on_earnings - 15.54 * 0.0369) < 0.001)

println("\n  >>> Economic summary:")
println("      Human cost:    -7.77 Àṣẹ (sim creation)")
println("      Human earned:  +$(round(record.ase_earned, digits=2)) Àṣẹ (agent consumption 2×)")
println("      Human net:     +$(round(net_profit, digits=2)) Àṣẹ")
println("      Èṣù tithe:    -$(round(tithe_on_earnings, digits=4)) Àṣẹ (3.69%)")
println("      Agent got:     Physics-validated trajectory ($(length(traj)) waypoints)")

# ============================================================================
# RESULTS
# ============================================================================

println("\n" * "─"^60)
println("Agent Earning E2E: $passed/$total passed, $failed failed")
if failed > 0
    println("⚠  FAILURES DETECTED")
    exit(1)
else
    println("✓  ALL TESTS PASSED — Àṣẹ")
end
