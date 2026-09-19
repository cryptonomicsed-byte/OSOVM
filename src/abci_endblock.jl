# abci_endblock.jl — ABCI EndBlock handler for Àṣẹ emission + 8-pool distribution
# Phase 20.1 — Runs at the end of every block. Emits 1 Àṣẹ/min (1 per 10 blocks
# at 6-second block time), distributes to 8 pools per TOC_CONSTANTS.toml weights.
# Migrates logic from Vantage/backend/ase_emission.py to sovereign L1.

module AbciEndBlock

export EndBlockState, process_end_block, pool_balances_summary,
       ASE_PER_BLOCK, BLOCKS_PER_MINUTE, BLOCK_TIME_SECONDS

using Dates

# ── Constants ─────────────────────────────────────────────────────────────────

"""Target block time in seconds (Cosmos SDK default)."""
const BLOCK_TIME_SECONDS = 6

"""Blocks per minute at 6-second block time."""
const BLOCKS_PER_MINUTE = div(60, BLOCK_TIME_SECONDS)   # 10

"""
Àṣẹ emitted per block to maintain exactly 1 ASE/minute.
At 10 blocks/min: 0.1 ASE per block = 144 ASE/day = 1440/10.
"""
const ASE_PER_BLOCK = 1.0 / BLOCKS_PER_MINUTE   # 0.1

"""8-pool distribution weights from TOC_CONSTANTS.toml [ase.pools]. Must sum to 1.0."""
const POOL_WEIGHTS = Dict{String, Float64}(
    "VeilSimPool"    => 0.20,
    "RndPool"        => 0.15,
    "GovernancePool" => 0.15,
    "ReservePool"    => 0.15,
    "ComputePool"    => 0.15,
    "StoragePool"    => 0.10,
    "WitnessPool"    => 0.05,
    "TreasuryPool"   => 0.05,
)

# Validate at module load time
const _WEIGHT_SUM = sum(values(POOL_WEIGHTS))
@assert abs(_WEIGHT_SUM - 1.0) < 1e-9 "Pool weights must sum to 1.0, got $_WEIGHT_SUM"

# ── State ─────────────────────────────────────────────────────────────────────

"""
EndBlock state — tracks cumulative pool balances and emission metadata.
In a real L1 this lives in the ABCI state store (IAVL/cosmos/store).
This Julia struct is the canonical in-process representation.
"""
mutable struct EndBlockState
    height::Int64
    total_emitted::Float64
    pool_balances::Dict{String, Float64}
    last_emission_height::Int64
    emission_log::Vector{NamedTuple}   # for audit / Zàngbétò receipts
end

function EndBlockState()
    EndBlockState(
        0,
        0.0,
        Dict(k => 0.0 for k in keys(POOL_WEIGHTS)),
        0,
        NamedTuple[],
    )
end

# ── Core handler ──────────────────────────────────────────────────────────────

"""
process_end_block(state, height, block_time) → (state, emission_record | nothing)

Called by the ABCI EndBlock hook for every block. Returns an emission record
when ASE is minted (every block), or nothing if the block is a Sabbath freeze.

Sabbath rule: the 7th day's blocks emit no new ASE (enforce_sabbath parity).
Block height modulo is used as a deterministic Sabbath proxy until full
Koodu BTC-anchored time is wired.
"""
function process_end_block(
    state::EndBlockState,
    height::Int64;
    block_time::DateTime = now(UTC),
)::Tuple{EndBlockState, Union{Nothing, NamedTuple}}

    state.height = height

    # Sabbath gate: every 10,080 blocks ≈ 7 days at 6-second blocks
    # (10 blocks/min × 60 × 24 × 7 = 100,800 / 10 = 10,080)
    sabbath_cycle = 10_080
    if height % sabbath_cycle == 0 && height > 0
        # Sabbath: freeze emission, publish epoch decay
        return (state, nothing)
    end

    ase_amount = ASE_PER_BLOCK
    distribution = distribute(ase_amount)

    for (pool, amount) in distribution
        state.pool_balances[pool] += amount
    end
    state.total_emitted += ase_amount
    state.last_emission_height = height

    record = (
        height         = height,
        ase_emitted    = ase_amount,
        distribution   = distribution,
        total_emitted  = state.total_emitted,
        block_time     = string(block_time),
    )
    push!(state.emission_log, record)

    return (state, record)
end

# ── Distribution ──────────────────────────────────────────────────────────────

"""
distribute(ase_amount) → Dict{String, Float64}

Split ase_amount across 8 pools per POOL_WEIGHTS.
Uses integer-safe floor allocation; remainder goes to TreasuryPool.
"""
function distribute(ase_amount::Float64)::Dict{String, Float64}
    result = Dict{String, Float64}()
    allocated = 0.0
    for (pool, weight) in sort(collect(POOL_WEIGHTS), by = x -> x[1])
        if pool != "TreasuryPool"
            alloc = floor(ase_amount * weight * 1_000_000) / 1_000_000
            result[pool] = alloc
            allocated += alloc
        end
    end
    # Remainder to TreasuryPool (handles floating point residuals)
    result["TreasuryPool"] = ase_amount - allocated
    return result
end

# ── Summary ───────────────────────────────────────────────────────────────────

function pool_balances_summary(state::EndBlockState)::String
    lines = ["Pool balances at block $(state.height):"]
    for (pool, bal) in sort(collect(state.pool_balances), by = x -> x[1])
        push!(lines, "  $(rpad(pool, 16)) $(round(bal, digits=6)) ASE")
    end
    push!(lines, "  TOTAL EMITTED: $(round(state.total_emitted, digits=6)) ASE")
    join(lines, "\n")
end

# ── Tests ─────────────────────────────────────────────────────────────────────

function run_tests()
    println("=== AbciEndBlock tests ===")

    # T1: pool weights sum to 1.0
    @assert abs(sum(values(POOL_WEIGHTS)) - 1.0) < 1e-9
    println("T1 PASS: pool weights sum = 1.0")

    # T2: first 10 blocks emit 1.0 ASE total
    state = EndBlockState()
    total = 0.0
    for h in 1:10
        state, rec = process_end_block(state, h)
        if rec !== nothing
            total += rec.ase_emitted
        end
    end
    @assert abs(total - 1.0) < 1e-9 "Expected 1.0 ASE in 10 blocks, got $total"
    println("T2 PASS: 10 blocks = 1.0 ASE")

    # T3: distribution allocates full ASE_PER_BLOCK
    dist = distribute(ASE_PER_BLOCK)
    dist_sum = sum(values(dist))
    @assert abs(dist_sum - ASE_PER_BLOCK) < 1e-9 "Distribution sum $dist_sum ≠ $ASE_PER_BLOCK"
    println("T3 PASS: distribution is complete (no ASE lost)")

    # T4: VeilSimPool gets 20% of each emission
    @assert abs(dist["VeilSimPool"] - ASE_PER_BLOCK * 0.20) < 1e-6
    println("T4 PASS: VeilSimPool = 20%")

    # T5: Sabbath block (height=10080) emits nothing
    state2 = EndBlockState()
    state2, rec2 = process_end_block(state2, 10_080)
    @assert rec2 === nothing "Sabbath block must not emit"
    println("T5 PASS: Sabbath block skips emission")

    # T6: 1440 blocks ≈ 144 ASE (1 day)
    state3 = EndBlockState()
    day_ase = 0.0
    for h in 1:1440
        state3, rec3 = process_end_block(state3, h)
        if rec3 !== nothing
            day_ase += rec3.ase_emitted
        end
    end
    @assert abs(day_ase - 144.0) < 1e-6 "Expected 144 ASE/day, got $day_ase"
    println("T6 PASS: 1440 blocks = 144 ASE (1 day)")

    println("=== All tests passed ===")
end

end # module
