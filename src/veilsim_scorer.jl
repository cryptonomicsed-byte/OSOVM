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

export veil_f1_score, score_veil_execution, calculate_reward,
       should_mint_ase, veil_scoring_event, VeilScoringRecord

# ============================================================================
# CONSTANTS
# ============================================================================

"""F1 score threshold for Àṣẹ minting"""
const F1_THRESHOLD = 0.9

"""Base Àṣẹ reward for F1 >= threshold"""
const BASE_ASE_REWARD = 5.0

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
    
    # Calculate reward
    ase_amount = if f1 >= F1_THRESHOLD
        calculate_reward(f1)
    else
        0.0
    end
    
    return VeilScoringRecord(
        veil_id,
        now(),
        f1,
        p,
        r,
        acc,
        metrics.execution_time,
        ase_amount,
        !isempty(wallet) ? wallet : nothing,
        "Veil $(veil.name) scored"
    )
end

"""
    calculate_reward(f1_score::Float64) -> Float64

Calculate Àṣẹ reward based on F1 score.
Base reward (5.0) for F1 >= 0.9
Bonuses for higher F1 scores
"""
function calculate_reward(f1_score::Float64)::Float64
    if f1_score < F1_THRESHOLD
        return 0.0
    end
    
    # Base reward
    reward = BASE_ASE_REWARD
    
    # Bonus tiers for higher F1
    if f1_score >= 0.95
        reward += 1.0  # +1.0 for F1 >= 0.95
    end
    
    if f1_score >= 0.98
        reward += 0.5  # +0.5 for F1 >= 0.98
    end
    
    if f1_score >= 0.99
        reward += 0.5  # +0.5 for F1 >= 0.99
    end
    
    return reward
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

"""
    score_all_veils(results::Dict) -> Dict

Score multiple veil executions.
"""
function score_all_veils(results::Dict)::Dict
    scoring_summary = Dict(
        "timestamp" => now(),
        "total_veils_scored" => 0,
        "veils_passing_threshold" => 0,
        "total_ase_minted" => 0.0,
        "average_f1" => 0.0,
        "by_veil" => Dict(),
        "scoring_records" => VeilScoringRecord[]
    )
    
    total_f1 = 0.0
    passing_count = 0
    
    for (veil_id, metrics) in results
        if isa(metrics, VeilMetrics)
            record = score_veil_execution(veil_id, metrics)
            veil_scoring_event(record)
            
            push!(scoring_summary["scoring_records"], record)
            
            scoring_summary["total_veils_scored"] += 1
            total_f1 += record.f1_score
            
            if should_mint_ase(record.f1_score)
                scoring_summary["veils_passing_threshold"] += 1
                passing_count += 1
            end
            
            scoring_summary["total_ase_minted"] += record.ase_minted
            
            scoring_summary["by_veil"][veil_id] = Dict(
                "f1_score" => record.f1_score,
                "ase_minted" => record.ase_minted,
                "precision" => record.precision,
                "recall" => record.recall
            )
        end
    end
    
    # Calculate averages
    if scoring_summary["total_veils_scored"] > 0
        scoring_summary["average_f1"] = total_f1 / scoring_summary["total_veils_scored"]
    end
    
    return scoring_summary
end

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
            "total_ase_minted" => 0.0,
            "average_f1" => 0.0
        )
    end
    
    total_ase = sum(r.ase_minted for r in SCORING_LOG)
    avg_f1 = mean(r.f1_score for r in SCORING_LOG)
    
    return Dict(
        "total_scoring_events" => length(SCORING_LOG),
        "total_ase_minted" => total_ase,
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
