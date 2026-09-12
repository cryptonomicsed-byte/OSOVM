# Simulation Pool 7-factor scoring.
#
# SimulationScore = Difficulty × Quality × Novelty × Verification
#                 × Independence × Utility × WitnessConfidence
#
# Each factor ∈ [0.0, 1.0]; composite = product of all.
# Economic weight for emission share — NOT the f1_score.
# Ported from sovereign-node/src/simulation_scoring.rs

module SimulationScoring

using Dates

# ── Factors ──────────────────────────────────────────────────────────────────

struct SimulationFactors
    difficulty::Float64          # f1_score / current_difficulty, clamped to 1.0
    quality::Float64             # raw f1_score from OSOVM
    novelty::Float64             # 1/sqrt(prior submissions same env_hash this epoch)
    verification::Float64        # fraction of verifiers that confirmed proof
    independence::Float64        # 1 - max_cosine_similarity vs other candidates
    utility::Float64             # T1=0.5 baseline … T5=1.0
    witness_confidence::Float64  # Σ(weight) / num_witnesses
end

SimulationFactors() = SimulationFactors(1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0)

function score(f::SimulationFactors)::Float64
    clamp(f.difficulty, 0.0, 1.0) *
    clamp(f.quality, 0.0, 1.0) *
    clamp(f.novelty, 0.0, 1.0) *
    clamp(f.verification, 0.0, 1.0) *
    clamp(f.independence, 0.0, 1.0) *
    clamp(f.utility, 0.0, 1.0) *
    clamp(f.witness_confidence, 0.0, 1.0)
end

# 1/sqrt(n), n ≥ 1
novelty_from_prior_count(n::Int)::Float64 = 1.0 / sqrt(max(n, 1))

# f1 / difficulty, clamped to [0,1]
function difficulty_factor(f1_score::Float64, current_difficulty::Float64)::Float64
    current_difficulty <= 0.0 && return 1.0
    clamp(f1_score / current_difficulty, 0.0, 1.0)
end

# Utility baseline by tier index (0=T1 … 4=T5)
function utility_for_tier(tier_index::Int)::Float64
    tiers = [0.50, 0.65, 0.80, 0.90, 1.00]
    tier_index < length(tiers) ? tiers[tier_index+1] : 1.00
end

# ── Result ───────────────────────────────────────────────────────────────────

struct SimulationScoreResult
    proof_id::String
    worker_did::String
    factors::SimulationFactors
    score::Float64
    share::Float64      # fraction of pool minute tick; caller normalises
    timestamp::Int64
end

# ── Emission share normalisation ─────────────────────────────────────────────

# Returns [(proof_id, share)] normalised to sum = 1.0.
function compute_emission_shares(scores::Vector{Tuple{String,Float64}})::Vector{Tuple{String,Float64}}
    total = sum(s for (_, s) in scores; init=0.0)
    if total <= 0.0
        n = length(scores)
        equal = n > 0 ? 1.0 / n : 0.0
        return [(id, equal) for (id, _) in scores]
    end
    [(id, s / total) for (id, s) in scores]
end

end # module
