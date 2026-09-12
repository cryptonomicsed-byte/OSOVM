# Proof-of-Evolution engine.
# Evaluates SimulationProof → ProofEvaluation.
# Anti-farming: novelty decays with repeated environment_hash.
# Ported from sovereign-node/src/proof_engine.rs

module ProofEngine

using Dates

# ── Novelty tracker ─────────────────────────────────────────────────────────

mutable struct NoveltyLedger
    counts::Dict{String,Int}
    lock::ReentrantLock
end
NoveltyLedger() = NoveltyLedger(Dict{String,Int}(), ReentrantLock())

# Returns novelty score: 1.0 for first submission, decaying as 1/sqrt(n).
function record!(ledger::NoveltyLedger, env_hash::String)::Float64
    lock(ledger.lock) do
        n = get(ledger.counts, env_hash, 0) + 1
        ledger.counts[env_hash] = n
        1.0 / sqrt(n)
    end
end

function count(ledger::NoveltyLedger, env_hash::String)::Int
    lock(ledger.lock) do
        get(ledger.counts, env_hash, 0)
    end
end

# ── Proof domain ─────────────────────────────────────────────────────────────

@enum ProofDomain Simulation Spatial Physical

# ── Proof evaluation ─────────────────────────────────────────────────────────

const MINT_THRESHOLD = 0.3

struct ProofEvaluation
    proof_id::String
    domain::ProofDomain
    difficulty::Float64
    quality::Float64
    novelty::Float64
    verification::Float64
    independence::Float64
    utility::Float64
    proof_value::Float64   # product of all factors
    mint_eligible::Bool
end

function compute_evaluation(
    proof_id::String,
    domain::ProofDomain,
    difficulty::Float64,
    quality::Float64,
    novelty::Float64,
    verification::Float64,
    independence::Float64,
    utility::Float64,
)::ProofEvaluation
    value = clamp(difficulty, 0.0, 1.0) *
            clamp(quality,    0.0, 1.0) *
            clamp(novelty,    0.0, 1.0) *
            clamp(verification, 0.0, 1.0) *
            clamp(independence, 0.0, 1.0) *
            clamp(utility,    0.0, 1.0)
    ProofEvaluation(proof_id, domain, difficulty, quality, novelty,
                    verification, independence, utility, value, value >= MINT_THRESHOLD)
end

# ── Engine ───────────────────────────────────────────────────────────────────

mutable struct Engine
    novelty::NoveltyLedger
end
Engine() = Engine(NoveltyLedger())

function evaluate_simulation(engine::Engine, proof::Dict)::ProofEvaluation
    env_hash    = get(proof, "environment_hash", "")
    trajectory  = get(proof, "trajectory_hash", "")
    checkpoint  = get(proof, "checkpoint_root", "")
    sensor      = get(proof, "sensor_hash", "")
    sig         = get(proof, "signature", "")
    metrics     = get(proof, "metrics", Dict())
    crashes     = get(metrics, "crashes", 1)

    difficulty   = max(get(proof, "difficulty", 1.0), 0.0)
    quality      = crashes == 0 ? get(metrics, "controller_stability", 0.8) : 0.0
    novelty      = record!(engine.novelty, env_hash)
    verification = (!isempty(trajectory) ? 0.3 : 0.0) +
                   (!isempty(checkpoint) ? 0.3 : 0.0) +
                   (!isempty(sensor)     ? 0.2 : 0.0) +
                   (!isempty(sig)        ? 0.2 : 0.0)
    independence = 0.8   # stub — real: witness chain check
    gates_cleared = get(metrics, "gates_cleared", 0)
    gates_total   = max(get(metrics, "gates_total", 1), 1)
    utility = clamp((gates_cleared / gates_total) * 0.6 +
                    get(metrics, "controller_stability", 0.0) * 0.4, 0.0, 1.0)

    compute_evaluation(get(proof, "proof_id", ""), Simulation,
        difficulty, quality, novelty, verification, independence, utility)
end

function evaluate_gaussian(engine::Engine, proof::Dict)::Union{ProofEvaluation, String}
    quality_agg = get(get(proof, "quality", Dict()), "aggregate", 0.0)
    if quality_agg < 0.3
        return "gaussian quality below minimum threshold (0.3)"
    end
    env_hash     = get(proof, "splat_hash", "")
    difficulty   = max(get(proof, "difficulty", 1.0), 0.0)
    quality      = get(proof, "quality_score", quality_agg)
    novelty      = record!(engine.novelty, env_hash)
    sig          = get(proof, "signature", "")
    verification = isempty(sig) ? 0.6 : 0.9
    wc           = get(get(proof, "quality", Dict()), "witness_count", 0)
    independence = min(1.0 + wc * 0.15, 1.0)
    utility      = get(get(proof, "quality", Dict()), "area_novelty_factor", 0.0) / 3.0

    compute_evaluation(get(proof, "proof_id", ""), Spatial,
        difficulty, quality, novelty, verification, independence, utility)
end

end # module
