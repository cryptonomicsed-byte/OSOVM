# Zangbeto Receipt System — Julia CBOR Generation + Move Verification
# Generates tamper-proof audit receipts for veil executions
# 7/12 witness quorum enforcement
# Crown Architect: Bino EL Gua Omo Koda Ase

module ZangbetoReceipts

using Dates
using SHA

include("seal_bridge.jl")
using .SealBridge

include("job_spec.jl")
using .JobSpec

include("merkle.jl")
using .Merkle

include("checkpoint_export.jl")
using .CheckpointExport

export ZangbetoReceipt, WitnessVote, ReceiptBundle
export create_receipt, encode_cbor, verify_receipt
export collect_witness_votes, check_quorum
export generate_move_verify_call, receipt_to_anchor
export JobReceiptBundle, create_job_receipt

# ============================================================================
# 1. RECEIPT DATA STRUCTURES
# ============================================================================

const QUORUM_REQUIRED = 7
const TOTAL_WITNESSES = 12

struct ZangbetoReceipt
    receipt_id::String
    sim_id::String
    creator_wallet::String
    timestamp::DateTime

    # Execution data
    veil_ids::Vector{Int}
    opcodes_executed::Vector{String}
    entity_count::Int
    step_count::Int

    # Metrics
    f1_score::Float64
    energy_drift::Float64
    robustness::Float64

    # Hashes
    execution_hash::String     # SHA-256 of execution data
    trajectory_hash::String    # SHA-256 of trajectory data
    receipt_hash::String       # SHA-256 of entire receipt

    # Chain anchoring
    block_height::Int
    chain_target::String       # "sui", "arweave", "ethereum"
end

struct WitnessVote
    witness_id::Int            # 0-11
    receipt_hash::String
    approved::Bool
    witness_hash::String       # Deterministic witness signature
    voted_at::DateTime
end

struct ReceiptBundle
    receipt::ZangbetoReceipt
    votes::Vector{WitnessVote}
    quorum_met::Bool
    total_approvals::Int
    status::String             # "VERIFIED", "SLASHED", "QUORUM_FAILED"
    seal::String               # Layer 1: SHA-256 tamper-evidence commitment
                                # (always present, VM-native, no external deps)
    seal_dek_fingerprint::String
                                # Layer 2 ("dual seal"): SHA-256 fingerprint of a
                                # real DEK fetched from Sui Seal's decentralized
                                # key servers (see seal_bridge.jl), proving a real
                                # Seal consultation gated this receipt. Empty
                                # string when SEAL_* env vars aren't configured
                                # (fail-open, same as Omo-Koda2's seal_bridge.rs)
                                # -- never a fake value.
end

"""
Receipt for the general Job → Proof flow (any SimJobSpec: OSOVM's own
:dsl veil catalog OR a :custom CubeSandbox-run arbitrary job). Unlike
ZangbetoReceipt (which is VeilSim-shaped: veil_ids, opcodes_executed),
this covers any job whose worker produced a checkpoint stream --
including sandboxes that ran outside this repo entirely. See
CUBESANDBOX_JOB_PIPELINE.md for the full external-worker contract this
receipt is the OSOVM-side half of.
"""
struct JobReceiptBundle
    job_id::String                  # JobSpec.job_id(spec) -- the spec's own hash
    spec_kind::Symbol                # :dsl or :custom
    creator_wallet::String
    checkpoint_count::Int
    checkpoint_merkle_root::String   # hex; the commitment validators sample against
    final_metrics::Dict{String, Float64}
    walrus_blob_id::String           # where the full checkpoint export actually lives
                                      # (uploaded by the worker -- OSOVM never uploads
                                      # storage itself, same pattern as glyphindex.jl)
    votes::Vector{WitnessVote}
    quorum_met::Bool
    total_approvals::Int
    status::String                   # "VERIFIED", "QUORUM_FAILED"
    seal::String                     # Layer 1: SHA-256 tamper-evidence commitment
    seal_dek_fingerprint::String     # Layer 2 ("dual seal"): see ReceiptBundle docstring
    created_at::DateTime
end

"""
Build a JobReceiptBundle from a validated SimJobSpec and the checkpoint
stream a worker (a CubeSandbox job or OSOVM's own VeilSim run) produced.
`walrus_blob_id` is caller-supplied -- the worker already uploaded the
full canonical checkpoint export before calling this (see
CheckpointExport.canonical_checkpoint_bytes / CUBESANDBOX_JOB_PIPELINE.md);
this function only ever handles the Merkle root and metrics, never the
raw checkpoint data or any storage upload itself.

Throws on an invalid spec or empty checkpoint list -- a receipt for a
job that produced no checkpoints or violates its own spec is not a
receipt, it's a lie.
"""
function create_job_receipt(spec::SimJobSpec, checkpoints::Vector{CheckpointExport.Checkpoint},
                             final_metrics::Dict{String, Float64}, walrus_blob_id::AbstractString)::JobReceiptBundle
    errors = validate_spec(spec)
    isempty(errors) || error("invalid job spec: $(join(errors, "; "))")
    isempty(checkpoints) && error("cannot create a receipt for zero checkpoints")

    for metric in spec.metrics_schema
        haskey(final_metrics, metric) || error("final_metrics missing declared metric \"$metric\"")
    end

    jid = job_id(spec)
    leaves = checkpoint_leaves(checkpoints)
    root = merkle_root(leaves)
    root_hex = bytes2hex(root)

    # f1_score, if the job declares it, drives the same witness-approval
    # threshold as the veil path; jobs that don't track f1_score at all
    # (a legitimate scientific-study job might not) fall back to the
    # lower base-approval threshold rather than crashing.
    f1 = get(final_metrics, "f1_score", 0.0)

    votes = collect_witness_votes(root_hex, f1)
    quorum_met, approvals = check_quorum(votes)
    status = quorum_met ? "VERIFIED" : "QUORUM_FAILED"

    # Layer 1: SHA-256 tamper-evidence commitment over the job identity
    # and its checkpoint root together (binds the receipt to BOTH which
    # job this is and what it actually produced).
    seal_data = "job-seal:$jid:$root_hex:$approvals"
    seal = bytes2hex(sha256(seal_data))[1:32]

    # Layer 2 ("dual seal"): real Sui Seal consultation, when configured.
    seal_dek_fingerprint = try
        fp = SealBridge.try_seal_fingerprint()
        fp === nothing ? "" : fp
    catch e
        @warn "Seal fetch configured but failed; falling back to SHA-256-only commitment" exception=e
        ""
    end

    println("[Zangbeto] Job $jid ($(spec.kind)): $status ($approvals/$TOTAL_WITNESSES witnesses, $(length(checkpoints)) checkpoints)")

    JobReceiptBundle(
        jid, spec.kind, spec.creator_wallet, length(checkpoints), root_hex,
        final_metrics, String(walrus_blob_id), votes, quorum_met, approvals,
        status, "job-$seal", seal_dek_fingerprint, now(),
    )
end

# ============================================================================
# 2. RECEIPT CREATION
# ============================================================================

"""
Create a Zangbeto receipt from simulation execution data.
"""
function create_receipt(
    sim_id::String,
    creator_wallet::String,
    veil_ids::Vector{Int},
    opcodes::Vector{String},
    entity_count::Int,
    step_count::Int,
    f1_score::Float64,
    energy_drift::Float64,
    robustness::Float64,
    trajectory_hash::String;
    block_height::Int = 0,
    chain_target::String = "sui"
)::ZangbetoReceipt

    ts = now()

    # Execution hash: deterministic from execution data
    exec_data = join([
        sim_id, creator_wallet,
        join(string.(veil_ids), ","),
        join(opcodes, ","),
        string(entity_count), string(step_count),
        string(f1_score), string(energy_drift)
    ], "|")
    execution_hash = bytes2hex(sha256(exec_data))

    # Receipt hash: covers everything
    receipt_data = join([
        execution_hash, trajectory_hash,
        string(ts), string(block_height),
        creator_wallet
    ], "|")
    receipt_hash = bytes2hex(sha256(receipt_data))

    receipt_id = "zang_$(sim_id)_$(receipt_hash[1:8])"

    ZangbetoReceipt(
        receipt_id, sim_id, creator_wallet, ts,
        veil_ids, opcodes, entity_count, step_count,
        f1_score, energy_drift, robustness,
        execution_hash, trajectory_hash, receipt_hash,
        block_height, chain_target
    )
end

# ============================================================================
# 3. CBOR ENCODING — Compact Binary Object Representation
# ============================================================================

"""
Encode receipt as CBOR binary format.
CBOR (RFC 8949) is a compact, self-describing binary format
used for blockchain anchoring and cross-chain verification.

This is a minimal CBOR encoder sufficient for receipt data.
"""
function encode_cbor(receipt::ZangbetoReceipt)::Vector{UInt8}
    buf = UInt8[]

    # CBOR map with 14 fields (major type 5, length 14)
    push!(buf, 0xa0 | 14)  # Map of 14 items

    # Helper: encode text string
    function cbor_text!(buf::Vector{UInt8}, s::String)
        bytes = Vector{UInt8}(s)
        n = length(bytes)
        if n < 24
            push!(buf, 0x60 | UInt8(n))
        elseif n < 256
            push!(buf, 0x78); push!(buf, UInt8(n))
        else
            push!(buf, 0x79)
            push!(buf, UInt8((n >> 8) & 0xFF))
            push!(buf, UInt8(n & 0xFF))
        end
        append!(buf, bytes)
    end

    # Helper: encode unsigned integer
    function cbor_uint!(buf::Vector{UInt8}, n::Int)
        if n < 0
            # Negative: major type 1
            nn = UInt64(-n - 1)
            if nn < 24
                push!(buf, 0x20 | UInt8(nn))
            else
                push!(buf, 0x39)
                push!(buf, UInt8((nn >> 8) & 0xFF))
                push!(buf, UInt8(nn & 0xFF))
            end
        elseif n < 24
            push!(buf, UInt8(n))
        elseif n < 256
            push!(buf, 0x18); push!(buf, UInt8(n))
        elseif n < 65536
            push!(buf, 0x19)
            push!(buf, UInt8((n >> 8) & 0xFF))
            push!(buf, UInt8(n & 0xFF))
        else
            push!(buf, 0x1a)
            push!(buf, UInt8((n >> 24) & 0xFF))
            push!(buf, UInt8((n >> 16) & 0xFF))
            push!(buf, UInt8((n >> 8) & 0xFF))
            push!(buf, UInt8(n & 0xFF))
        end
    end

    # Helper: encode float64 (major type 7, additional 27)
    function cbor_float!(buf::Vector{UInt8}, f::Float64)
        push!(buf, 0xfb)  # Float64
        bytes = reinterpret(UInt8, [hton(f)])
        append!(buf, bytes)
    end

    # Helper: encode array of ints
    function cbor_int_array!(buf::Vector{UInt8}, arr::Vector{Int})
        n = length(arr)
        if n < 24
            push!(buf, 0x80 | UInt8(n))
        else
            push!(buf, 0x98); push!(buf, UInt8(n))
        end
        for v in arr
            cbor_uint!(buf, v)
        end
    end

    # Helper: encode array of strings
    function cbor_string_array!(buf::Vector{UInt8}, arr::Vector{String})
        n = length(arr)
        if n < 24
            push!(buf, 0x80 | UInt8(n))
        else
            push!(buf, 0x98); push!(buf, UInt8(n))
        end
        for s in arr
            cbor_text!(buf, s)
        end
    end

    # Encode each field
    cbor_text!(buf, "receipt_id");     cbor_text!(buf, receipt.receipt_id)
    cbor_text!(buf, "sim_id");        cbor_text!(buf, receipt.sim_id)
    cbor_text!(buf, "creator");       cbor_text!(buf, receipt.creator_wallet)
    cbor_text!(buf, "timestamp");     cbor_text!(buf, string(receipt.timestamp))
    cbor_text!(buf, "veil_ids");      cbor_int_array!(buf, receipt.veil_ids)
    cbor_text!(buf, "opcodes");       cbor_string_array!(buf, receipt.opcodes_executed)
    cbor_text!(buf, "entities");      cbor_uint!(buf, receipt.entity_count)
    cbor_text!(buf, "steps");         cbor_uint!(buf, receipt.step_count)
    cbor_text!(buf, "f1_score");      cbor_float!(buf, receipt.f1_score)
    cbor_text!(buf, "energy_drift");  cbor_float!(buf, receipt.energy_drift)
    cbor_text!(buf, "exec_hash");     cbor_text!(buf, receipt.execution_hash)
    cbor_text!(buf, "traj_hash");     cbor_text!(buf, receipt.trajectory_hash)
    cbor_text!(buf, "receipt_hash");  cbor_text!(buf, receipt.receipt_hash)
    cbor_text!(buf, "block_height");  cbor_uint!(buf, receipt.block_height)

    return buf
end

"""
Compute CBOR hash for on-chain verification.
"""
function cbor_hash(receipt::ZangbetoReceipt)::String
    cbor_bytes = encode_cbor(receipt)
    bytes2hex(sha256(cbor_bytes))
end

# ============================================================================
# 4. WITNESS QUORUM — 7/12 Deterministic Verification
# ============================================================================

"""Generic core: witness simulation over any (receipt_hash, f1_score)
pair, independent of which receipt struct produced them. Shared by
collect_witness_votes(::ZangbetoReceipt) and the job-receipt path
(create_job_receipt) so both use the identical, single witness-approval
algorithm rather than two copies drifting apart."""
function collect_witness_votes(receipt_hash::AbstractString, f1_score::Float64)::Vector{WitnessVote}
    votes = WitnessVote[]

    for w in 0:(TOTAL_WITNESSES-1)
        # Deterministic witness hash
        witness_data = "witness-$w-$receipt_hash"
        witness_hash = bytes2hex(sha256(witness_data))

        # Witness approves if hash starts with 0-b (75% base approval rate)
        # High-F1 sims get higher approval (first char < 'd' = 81%)
        threshold = f1_score >= 0.9 ? 'd' : 'c'
        approved = witness_hash[1] < threshold

        push!(votes, WitnessVote(
            w,
            String(receipt_hash),
            approved,
            witness_hash,
            now()
        ))
    end

    votes
end

collect_witness_votes(receipt::ZangbetoReceipt)::Vector{WitnessVote} =
    collect_witness_votes(receipt.receipt_hash, receipt.f1_score)

"""
Check if quorum is met (7/12 witnesses must approve).
"""
function check_quorum(votes::Vector{WitnessVote})::Tuple{Bool, Int}
    approvals = count(v -> v.approved, votes)
    (approvals >= QUORUM_REQUIRED, approvals)
end

"""
Verify a receipt: generate CBOR, collect witnesses, check quorum.
Returns a complete ReceiptBundle.
"""
function verify_receipt(receipt::ZangbetoReceipt)::ReceiptBundle
    # Collect witness votes
    votes = collect_witness_votes(receipt)
    quorum_met, approvals = check_quorum(votes)

    # Determine status
    status = if quorum_met
        "VERIFIED"
    else
        "QUORUM_FAILED"
    end

    # Layer 1: SHA-256 tamper-evidence commitment (always present)
    seal_data = "zangbeto-seal:$(receipt.receipt_hash):$approvals"
    seal = bytes2hex(sha256(seal_data))[1:32]

    # Layer 2 ("dual seal"): real Sui Seal consultation, when configured.
    # Fail-open: unconfigured -> empty string; misconfigured (throws) ->
    # logged and left empty, never faked as if it succeeded.
    seal_dek_fingerprint = try
        fp = SealBridge.try_seal_fingerprint()
        fp === nothing ? "" : fp
    catch e
        @warn "Seal fetch configured but failed; falling back to SHA-256-only commitment" exception=e
        ""
    end

    println("[Zangbeto] Receipt $(receipt.receipt_id): $status ($approvals/$TOTAL_WITNESSES witnesses)")

    ReceiptBundle(
        receipt, votes, quorum_met, approvals, status,
        "zang-$seal", seal_dek_fingerprint
    )
end

# ============================================================================
# 5. MOVE CONTRACT INTEGRATION — Sui On-Chain Verification
# ============================================================================

"""
Generate a Move contract call for on-chain receipt verification.
This produces the transaction payload that a Sui client would submit.
"""
function generate_move_verify_call(bundle::ReceiptBundle)::Dict{String, Any}
    r = bundle.receipt

    Dict{String, Any}(
        "module" => "zangbeto_verifier",
        "function" => "verify_receipt",
        "type_arguments" => String[],
        "arguments" => [
            r.receipt_hash,                    # receipt_hash: vector<u8>
            cbor_hash(r),                      # cbor_hash: vector<u8>
            r.creator_wallet,                  # creator: address
            r.f1_score,                        # f1_score: u64 (scaled by 1000)
            bundle.total_approvals,            # witness_count: u64
            QUORUM_REQUIRED,                   # quorum_required: u64
            bundle.seal,                       # seal: vector<u8>
            r.block_height                     # block_height: u64
        ],
        "move_contract" => """
module zangbeto::verifier {
    use sui::object::{Self, UID};
    use sui::tx_context::TxContext;
    use sui::transfer;
    use sui::event;

    struct VerifiedReceipt has key, store {
        id: UID,
        receipt_hash: vector<u8>,
        cbor_hash: vector<u8>,
        creator: address,
        f1_score: u64,
        witness_count: u64,
        quorum_required: u64,
        seal: vector<u8>,
        block_height: u64,
        verified: bool,
    }

    struct ReceiptVerified has copy, drop {
        receipt_hash: vector<u8>,
        creator: address,
        f1_score: u64,
        witness_count: u64,
    }

    public entry fun verify_receipt(
        receipt_hash: vector<u8>,
        cbor_hash: vector<u8>,
        creator: address,
        f1_score: u64,
        witness_count: u64,
        quorum_required: u64,
        seal: vector<u8>,
        block_height: u64,
        ctx: &mut TxContext,
    ) {
        assert!(witness_count >= quorum_required, 0x001);
        assert!(f1_score >= 777, 0x002);

        let receipt = VerifiedReceipt {
            id: object::new(ctx),
            receipt_hash,
            cbor_hash,
            creator,
            f1_score,
            witness_count,
            quorum_required,
            seal,
            block_height,
            verified: true,
        };

        event::emit(ReceiptVerified {
            receipt_hash: receipt.receipt_hash,
            creator,
            f1_score,
            witness_count,
        });

        transfer::public_share_object(receipt);
    }
}
"""
    )
end

# ============================================================================
# 6. ANCHORING — Multi-Chain Receipt Submission
# ============================================================================

"""
Generate anchoring data for a verified receipt bundle.
Returns chain-specific payloads for Bitcoin, Arweave, Ethereum, and Sui.
"""
function receipt_to_anchor(bundle::ReceiptBundle)::Dict{String, Any}
    r = bundle.receipt
    cbor_h = cbor_hash(r)

    Dict{String, Any}(
        "receipt_id" => r.receipt_id,
        "status" => bundle.status,
        "seal" => bundle.seal,
        "seal_dek_fingerprint" => bundle.seal_dek_fingerprint,
        "anchors" => Dict(
            "bitcoin" => Dict(
                "method" => "OP_RETURN",
                "data" => "0x$(r.receipt_hash[1:16])"
            ),
            "arweave" => Dict(
                "method" => "TX_DATA",
                "tags" => Dict(
                    "App-Name" => "Zangbeto",
                    "Receipt-Hash" => r.receipt_hash,
                    "CBOR-Hash" => cbor_h,
                    "F1-Score" => string(r.f1_score),
                    "Witnesses" => string(bundle.total_approvals)
                )
            ),
            "ethereum" => Dict(
                "method" => "LOG_EVENT",
                "data" => "0x$cbor_h"
            ),
            "sui" => generate_move_verify_call(bundle)
        )
    )
end

end # module ZangbetoReceipts
