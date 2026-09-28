"""
    VeilSimScorer - F1-based veil simulation scoring and Àṣẹ rewards
    
Evaluates veil execution quality via F1 scores and mints Àṣẹ rewards.
"""

module VeilSimScorer

using Dates

include("veils_777.jl")
include("veil_index.jl")

using .Veils777
using .VeilIndex

export veil_f1_score, score_veil_execution,
       should_mint_ase, veil_scoring_event, VeilScoringRecord

# ============================================================================
# CONSTANTS
# ============================================================================

"""F1 score quality gate — sims below this threshold are not recorded as passing."""
const F1_THRESHOLD = 0.9

"""F1 score is tracked as percentage (0-100)"""
const F1_SCALE = 100.0

# ============================================================================
# SCORING DATA STRUCTURES
# ============================================================================

"""Record of a veil scoring event"""
struct VeilScoringRecord
    veil_id::Int
    timestamp::DateTime
    f1_score::Float64
    precision::Float64
    recall::Float64
    accuracy::Float64
    execution_time::Float64
    ase_minted::Float64
    wallet_address::Union{String, Nothing}
    notes::String
end

"""Comprehensive veil execution metrics"""
struct VeilMetrics
    veil_id::Int
    true_positives::Int
    false_positives::Int
    false_negatives::Int
    true_negatives::Int
    execution_time::Float64
    memory_used::Int  # bytes
    energy_used::Float64  # joules equivalent
end

# ============================================================================
# F1 SCORE CALCULATION
# ============================================================================

"""
    precision(tp::Int, fp::Int) -> Float64

Calculate precision from true positives and false positives.
Precision = TP / (TP + FP)
"""
function precision(tp::Int, fp::Int)::Float64
    if tp + fp == 0
        return 0.0
    end
    return tp / (tp + fp)
end

"""
    recall(tp::Int, fn::Int) -> Float64

Calculate recall from true positives and false negatives.
Recall = TP / (TP + FN)
"""
function recall(tp::Int, fn::Int)::Float64
    if tp + fn == 0
        return 0.0
    end
    return tp / (tp + fn)
end

"""
    f1_score(precision::Float64, recall::Float64) -> Float64

Calculate F1 score from precision and recall.
F1 = 2 * (precision * recall) / (precision + recall)
"""
function f1_score(precision::Float64, recall::Float64)::Float64
    if precision + recall == 0
        return 0.0
    end
    return 2.0 * (precision * recall) / (precision + recall)
end

"""
    accuracy(tp::Int, tn::Int, total::Int) -> Float64

Calculate accuracy from true positives, true negatives, and total.
Accuracy = (TP + TN) / Total
"""
function accuracy(tp::Int, tn::Int, total::Int)::Float64
    if total == 0
        return 0.0
    end
    return (tp + tn) / total
end

"""
    veil_f1_score(metrics::VeilMetrics) -> Float64

Calculate F1 score from veil execution metrics.
"""
function veil_f1_score(metrics::VeilMetrics)::Float64
    p = precision(metrics.true_positives, metrics.false_positives)
    r = recall(metrics.true_positives, metrics.false_negatives)
    return f1_score(p, r)
end

# ============================================================================
# VEIL SCORING
# ============================================================================

"""
    score_veil_execution(veil_id::Int, metrics::VeilMetrics, 
                        wallet::String = "") -> VeilScoringRecord

Score a veil execution and record results.
"""
function score_veil_execution(veil_id::Int, metrics::VeilMetrics, 
                             wallet::String = "")::VeilScoringRecord
    
    # Verify veil exists
    veil = lookup_veil(veil_id)
    if isnothing(veil)
        return VeilScoringRecord(
            veil_id, now(), 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, wallet, 
            "Veil $veil_id not found"
        )
    end
    
    # Calculate metrics
    p = precision(metrics.true_positives, metrics.false_positives)
    r = recall(metrics.true_positives, metrics.false_negatives)
    f1 = f1_score(p, r)
    total = metrics.true_positives + metrics.false_positives + 
            metrics.false_negatives + metrics.true_negatives
    acc = accuracy(metrics.true_positives, metrics.true_negatives, max(total, 1))
    
    # ASE issuance routes through the emission clock only (I-33).
    # ase_minted is always 0 here; the proof record feeds COMPUTE_PROOF (0x56)
    # which mints Synapse via TOC_MINT (0x54), never ASE directly.
    return VeilScoringRecord(
        veil_id,
        now(),
        f1,
        p,
        r,
        acc,
        metrics.execution_time,
        0.0,
        !isempty(wallet) ? wallet : nothing,
        "Veil $(veil.name) scored"
    )
end

"""
    should_mint_ase(f1_score::Float64) -> Bool

Determine if Àṣẹ should be minted for this F1 score.
"""
function should_mint_ase(f1_score::Float64)::Bool
    return f1_score >= F1_THRESHOLD
end

# ============================================================================
# SCORING EVENT TRACKING
# ============================================================================

"""Global scoring event log"""
const SCORING_LOG = VeilScoringRecord[]

"""
    veil_scoring_event(record::VeilScoringRecord)

Record a veil scoring event.
"""
function veil_scoring_event(record::VeilScoringRecord)
    push!(SCORING_LOG, record)
    
    # Emit event (for downstream processing)
    emit_scoring_event(record)
end

"""
    emit_scoring_event(record::VeilScoringRecord)

Emit scoring event to event listeners.
"""
function emit_scoring_event(record::VeilScoringRecord)
    # Event structure for downstream (blockchain, dashboard, etc)
    event = Dict(
        "type" => "VeilScored",
        "veil_id" => record.veil_id,
        "timestamp" => string(record.timestamp),
        "f1_score" => record.f1_score,
        "precision" => record.precision,
        "recall" => record.recall,
        "accuracy" => record.accuracy,
        "ase_minted" => record.ase_minted,
        "wallet" => record.wallet_address,
        "notes" => record.notes
    )
    
    # TODO: Emit to event bus / blockchain / dashboard
    # For now, just log
    if record.ase_minted > 0.0
        println("[VeilScored] $(record.veil_id): F1=$(record.f1_score), Àṣẹ=$(record.ase_minted)")
    end
    
    return event
end

# ============================================================================
# BATCH SCORING
# ============================================================================
# SCORING STATISTICS
# ============================================================================

"""
    get_scoring_stats() -> Dict

Get scoring statistics from event log.
"""
function get_scoring_stats()::Dict
    if isempty(SCORING_LOG)
        return Dict(
            "total_scoring_events" => 0,
            "total_ase_scored" => 0.0,
            "average_f1" => 0.0
        )
    end
    
    total_ase = sum(r.ase_minted for r in SCORING_LOG)
    avg_f1 = mean(r.f1_score for r in SCORING_LOG)
    
    return Dict(
        "total_scoring_events" => length(SCORING_LOG),
        "total_ase_scored" => total_ase,
        "average_f1" => avg_f1,
        "min_f1" => minimum(r.f1_score for r in SCORING_LOG),
        "max_f1" => maximum(r.f1_score for r in SCORING_LOG),
        "scoring_events_above_threshold" => count(r -> r.f1_score >= F1_THRESHOLD, SCORING_LOG)
    )
end

"""
    clear_scoring_log()

Clear the scoring event log.
"""
function clear_scoring_log()
    empty!(SCORING_LOG)
end

"""
    get_scoring_log(n::Int = -1) -> Vector{VeilScoringRecord}

Get scoring event log. If n > 0, return last n records.
"""
function get_scoring_log(n::Int = -1)::Vector{VeilScoringRecord}
    if n < 0
        return copy(SCORING_LOG)
    else
        return copy(SCORING_LOG[max(1, length(SCORING_LOG)-n+1):end])
    end
end

end # module VeilSimScorer
