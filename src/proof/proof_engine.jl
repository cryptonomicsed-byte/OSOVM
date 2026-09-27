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

# evaluate_simulation and evaluate_gaussian deleted (I-20 / 2026-09-27).
# Both had 0 callers, no exports, no tests — same class as mint_ase_for_veil.
# Their defaults (difficulty=1.0, quality=0.8/controller_stability, independence=0.8)
# conflicted with COMPUTE_PROOF's inline factor computation in oso_vm.jl, which
# is the only live path. compute_evaluation (above) is the canonical factor site.
# When domain-specific evaluators are needed, build them to call compute_evaluation
# with attested factors — not to supply generous defaults.

end # module
