# verification.jl — OSOVM Agent Verification Gate
#
# is_fully_verified() is the canonical gate for TOC_MINT (0x54).
# Two call signatures are provided:
#
#   1. vm_core path (VMState from vm_core.jl):
#      toc_is_fully_verified(state, agent_id, claimed_gpu_seconds)
#      → delegates to VMCore.toc_is_fully_verified (defined in vm_core.jl)
#
#   2. Agent-state path (Dict-based agent records):
#      is_fully_verified(agent_state)
#      → checks genesis_proof_id, tier, active_violations
#      → mirrors VerifiedGPUWork.is_fully_verified() from Omo-Koda2
#
# The agent-state variant is used by server.jl / the HTTP API when a caller
# passes a bare agent record rather than a full VMState snapshot.

module Verification

export is_fully_verified, agent_is_verified

"""
    is_fully_verified(agent_state::Dict) -> Bool

Check whether a bare agent-state Dict satisfies the verification gate:
  - has a genesis_proof_id (non-empty)
  - tier >= 1 (graduated from genesis tier)
  - no active violations

Mirrors `VerifiedGPUWork.is_fully_verified()` from
Omo-Koda2/omokoda-core/src/kernel/compute/verified_work.rs.

Fail-closed: any missing key returns false.
"""
function is_fully_verified(agent_state::Dict)::Bool
    has_genesis = !isempty(get(agent_state, "genesis_proof_id",
                               get(agent_state, :genesis_proof_id, "")))
    tier        = get(agent_state, "tier", get(agent_state, :tier, 0))
    violations  = get(agent_state, "active_violations",
                      get(agent_state, :active_violations, 1))

    return has_genesis && tier >= 1 && violations == 0
end

"""
    agent_is_verified(vm_agent_states::Dict, agent_id::String) -> Bool

Look up agent_id in a vm.agent_states Dict and apply is_fully_verified().
Returns false if agent_id is not present.
"""
function agent_is_verified(vm_agent_states::Dict, agent_id::String)::Bool
    if !haskey(vm_agent_states, agent_id)
        return false
    end
    is_fully_verified(vm_agent_states[agent_id])
end

end # module Verification
