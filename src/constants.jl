# constants.jl — Ọ̀ṢỌ́VM TOC Constants Bridge (Phase 20.3 + M3)
#
# Single source of truth: ~/sovereign-eco-blueprint/specs/TOC_CONSTANTS.toml
# All constant values are read from that file at startup.  If the file is
# absent (e.g. during CI in an isolated checkout) the hardcoded fallback
# values are IDENTICAL to the TOML — never independent.
#
# Rule: if you change a value here, change it in TOC_CONSTANTS.toml first.

module Constants

export TOC,
       ASE_EMISSION_PER_MINUTE,
       ASE_MICRO_PER_ASE,
       ASE_BIRTH_FEE,
       DOPAMINE_BIRTH_ENDOWMENT,
       DOPAMINE_DAILY_DECAY_RATE,
       DOPAMINE_ASE_TO_DOPAMINE,
       SYNAPSE_BIRTH_ENDOWMENT,
       SYNAPSE_DAILY_DECAY_RATE,
       SYNAPSE_CONVERSION_RATIO,
       ESU_TITHE_RATE,
       GATES_STAKE_FRACTION,
       GATES_GATE_COUNT,
       JOB_CREATOR_SHARE,
       JOB_BURN_SHARE,
       JOB_AGENT_SHARE,
       COMPUTE_PROOF_SCORING_THRESHOLD

using TOML

# ─────────────────────────────────────────────────────────────────────────────
# TOML LOADER
# Resolves path relative to this file so it works regardless of cwd.
# ─────────────────────────────────────────────────────────────────────────────

function load_toc_constants()::Dict{String, Any}
    # Two possible locations depending on checkout layout.
    candidates = [
        joinpath(@__DIR__, "..", "..", "sovereign-eco-blueprint", "specs", "TOC_CONSTANTS.toml"),
        expanduser("~/sovereign-eco-blueprint/specs/TOC_CONSTANTS.toml"),
    ]

    for toml_path in candidates
        if isfile(toml_path)
            data = TOML.parsefile(toml_path)
            return Dict{String, Any}(
                # [ase]
                "ase_emission_per_minute"     => data["ase"]["emission_per_minute"],
                "ase_micro_per_ase"           => data["ase"]["micro_per_ase"],
                "ase_birth_fee"               => data["ase"]["birth_fee"],
                # [dopamine]
                "dopamine_birth_endowment"    => data["dopamine"]["birth_endowment"],
                "dopamine_daily_decay_rate"   => data["dopamine"]["daily_decay_rate"],
                "dopamine_ase_to_dopamine"    => data["dopamine"]["ase_to_dopamine"],
                # [synapse]
                "synapse_birth_endowment"     => data["synapse"]["birth_endowment"],
                "synapse_daily_decay_rate"    => data["synapse"]["daily_decay_rate"],
                "synapse_conversion_ratio"    => data["synapse"]["conversion_ratio"],
                # [esu]
                "esu_tithe_rate"              => data["esu"]["tithe_rate"],
                # [gates]
                "gates_stake_fraction"        => data["gates"]["stake_fraction"],
                "gates_gate_count"            => data["gates"]["gate_count"],
                # [job_payment]
                "job_creator_share"           => data["job_payment"]["creator_share"],
                "job_burn_share"              => data["job_payment"]["burn_share"],
                "job_agent_share"             => data["job_payment"]["agent_share"],
                # [compute_proof]
                "compute_proof_scoring_threshold" => data["compute_proof"]["scoring_threshold"],
            )
        end
    end

    # Fallback: hardcoded values that EXACTLY match TOC_CONSTANTS.toml.
    # CI parity test should compare these against the TOML to detect drift.
    @warn "TOC_CONSTANTS.toml not found; using embedded fallback constants"
    return Dict{String, Any}(
        "ase_emission_per_minute"         => 1,
        "ase_micro_per_ase"               => 1_000_000,
        "ase_birth_fee"                   => 10.0,
        "dopamine_birth_endowment"        => 86_000_000_000,
        "dopamine_daily_decay_rate"       => 0.01,
        "dopamine_ase_to_dopamine"        => 10_000,
        "synapse_birth_endowment"         => 86_000_000,
        "synapse_daily_decay_rate"        => 0.01,
        "synapse_conversion_ratio"        => 0.1,
        "esu_tithe_rate"                  => 0.0369,
        "gates_stake_fraction"            => 0.10,
        "gates_gate_count"                => 7,
        "job_creator_share"               => 0.10,
        "job_burn_share"                  => 0.05,
        "job_agent_share"                 => 0.85,
        "compute_proof_scoring_threshold" => 0.777,
    )
end

# ─────────────────────────────────────────────────────────────────────────────
# LOAD AT MODULE IMPORT
# ─────────────────────────────────────────────────────────────────────────────

const TOC = load_toc_constants()

# ─────────────────────────────────────────────────────────────────────────────
# NAMED CONSTANTS (typed, for use without Dict lookup)
# Reference these in vm_core.jl instead of hardcoded literals.
# ─────────────────────────────────────────────────────────────────────────────

# [ase]
const ASE_EMISSION_PER_MINUTE     = TOC["ase_emission_per_minute"]::Int
const ASE_MICRO_PER_ASE           = TOC["ase_micro_per_ase"]::Int
const ASE_BIRTH_FEE               = Float64(TOC["ase_birth_fee"])

# [dopamine]
const DOPAMINE_BIRTH_ENDOWMENT    = TOC["dopamine_birth_endowment"]::Int
const DOPAMINE_DAILY_DECAY_RATE   = Float64(TOC["dopamine_daily_decay_rate"])
const DOPAMINE_ASE_TO_DOPAMINE    = TOC["dopamine_ase_to_dopamine"]::Int

# [synapse]
const SYNAPSE_BIRTH_ENDOWMENT     = TOC["synapse_birth_endowment"]::Int
const SYNAPSE_DAILY_DECAY_RATE    = Float64(TOC["synapse_daily_decay_rate"])
const SYNAPSE_CONVERSION_RATIO    = Float64(TOC["synapse_conversion_ratio"])

# [esu]
const ESU_TITHE_RATE              = Float64(TOC["esu_tithe_rate"])

# [gates]
const GATES_STAKE_FRACTION        = Float64(TOC["gates_stake_fraction"])
const GATES_GATE_COUNT            = TOC["gates_gate_count"]::Int

# [job_payment]
const JOB_CREATOR_SHARE           = Float64(TOC["job_creator_share"])
const JOB_BURN_SHARE              = Float64(TOC["job_burn_share"])
const JOB_AGENT_SHARE             = Float64(TOC["job_agent_share"])

# [compute_proof]
const COMPUTE_PROOF_SCORING_THRESHOLD = Float64(TOC["compute_proof_scoring_threshold"])

end # module Constants
