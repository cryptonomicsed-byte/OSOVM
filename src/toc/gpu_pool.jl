# OSOVM Token-of-Compute (ToC) GPU contribution pool.
#
# Architecture:
#   GPU  = Dopamine token  (supply cap: 86B micro-units)
#   Synapse = agent slice  (cap: 86M; earned by burning 10 GPU)
#   Decay: 1%/day on Synapse balances (not GPU)
#   Èṣù tithe: 3.69% of each GPU mint → protocol tithe wallet
#
# Ported from sovereign-node/src/gpu_pool.rs

module GpuPool

using Dates, UUIDs

const GPU_SUPPLY_CAP       = 86_000_000_000_000_000  # 86B × 10^9
const SYNAPSE_SUPPLY_CAP   =     86_000_000_000_000  # 86M × 10^9
const GPU_PER_SYNAPSE_BURN = 10
const ESHU_TITHE_BPS       = 369    # 3.69%
const DECAY_BPS_PER_DAY    = 100    # 1.00%

struct GpuContribution
    contribution_id::String
    contributor_did::String
    device_id::String
    compute_units::Int64
    proof_hash::String
    gpu_minted::Int64   # micro-GPU after tithe
    eshu_tithe::Int64
    timestamp::Int64
end

struct GpuPoolState
    total_compute_units::Int64
    total_gpu_minted::Int64
    total_eshu_tithe::Int64
    synapse_minted::Int64
    contribution_count::Int
    decay_bps_per_day::Int
    eshu_tithe_bps::Int
    last_decay_epoch_day::Int64
end

mutable struct Pool
    contributions::Vector{GpuContribution}
    gpu_balances::Dict{String,Int64}
    syn_balances::Dict{String,Int64}
    total_compute_units::Int64
    total_gpu_minted::Int64
    total_eshu_tithe::Int64
    synapse_minted::Int64
    last_decay_epoch_day::Int64
    lock::ReentrantLock
end
Pool() = Pool(GpuContribution[], Dict(), Dict(), 0, 0, 0, 0, 0, ReentrantLock())

function contribute!(pool::Pool, contributor_did::String, device_id::String,
                     compute_units::Int64, proof_hash::String)::GpuContribution
    lock(pool.lock) do
        gpu_gross  = compute_units
        eshu_tithe = div(gpu_gross * ESHU_TITHE_BPS, 10_000)
        gpu_net    = gpu_gross - eshu_tithe

        pool.gpu_balances[contributor_did] =
            get(pool.gpu_balances, contributor_did, 0) + gpu_net
        pool.total_compute_units += compute_units
        pool.total_gpu_minted    += gpu_gross
        pool.total_eshu_tithe    += eshu_tithe

        cid = "gpu:$(uuid4())"
        rec = GpuContribution(cid, contributor_did, device_id,
                              compute_units, proof_hash, gpu_net, eshu_tithe,
                              round(Int64, time() * 1000))
        push!(pool.contributions, rec)
        rec
    end
end

# Returns (synapses_minted, remaining_gpu) or throws on insufficient balance.
function burn_for_synapse!(pool::Pool, did::String, gpu_amount::Int64)
    lock(pool.lock) do
        bal = get(pool.gpu_balances, did, 0)
        bal < gpu_amount && error("insufficient GPU balance: have $bal, need $gpu_amount")
        pool.gpu_balances[did] = bal - gpu_amount
        synapses = div(gpu_amount, GPU_PER_SYNAPSE_BURN)
        pool.syn_balances[did] = get(pool.syn_balances, did, 0) + synapses
        pool.synapse_minted += synapses
        (synapses, pool.gpu_balances[did])
    end
end

# Apply 1%/day decay to all Synapse balances. Returns total micro-SYN burned.
# Idempotent: calling twice on the same epoch_day returns 0 on second call.
function apply_daily_decay!(pool::Pool, epoch_day::Int64)::Int64
    lock(pool.lock) do
        pool.last_decay_epoch_day >= epoch_day && return 0
        pool.last_decay_epoch_day = epoch_day
        total_decayed = 0
        for (did, bal) in pool.syn_balances
            decay = div(bal * DECAY_BPS_PER_DAY, 10_000)
            pool.syn_balances[did] = bal - decay
            total_decayed += decay
        end
        total_decayed
    end
end

gpu_balance(pool::Pool, did::String)     = get(pool.gpu_balances, did, 0)
synapse_balance(pool::Pool, did::String) = get(pool.syn_balances, did, 0)

function state(pool::Pool)::GpuPoolState
    lock(pool.lock) do
        GpuPoolState(pool.total_compute_units, pool.total_gpu_minted,
                     pool.total_eshu_tithe, pool.synapse_minted,
                     length(pool.contributions), DECAY_BPS_PER_DAY,
                     ESHU_TITHE_BPS, pool.last_decay_epoch_day)
    end
end

end # module
