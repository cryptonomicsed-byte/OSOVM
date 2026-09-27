# simulation_scoring.jl — DELETED (I-50 / 2026-09-27)
#
# This file was never included anywhere (0 callers, 0 imports).
# It carried four defects that would have activated on first wiring:
#
#   1. SimulationFactors() zero-arg constructor: all factors default to 1.0.
#      score() returns 1.0 from no input — perfect score for no work.
#
#   2. 7-factor product (added WitnessConfidence) diverging from the live
#      6-factor compute_evaluation in proof/proof_engine.jl — two definitions
#      of one thing with different factor sets. Same class as I-5/I-20.
#
#   3. difficulty_factor: current_difficulty <= 0.0 returns 1.0 (fail-open
#      full credit instead of fail-closed zero).
#
#   4. compute_emission_shares: zero total → equal shares for all, including
#      zero-scored proofs — unverified work receives emission shares.
#
# "Ported from sovereign-node/src/simulation_scoring.rs" in the header read
# like intent. If a 7-factor design is real, build it to call compute_evaluation
# with attested inputs — never wire the zero-arg constructor pattern.
