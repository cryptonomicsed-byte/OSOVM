# waggle_bridge.jl — ỌṢỌVM's connection to the Waggle stigmergic field.
#
# Connection Map v2 §1: the Techgnosis pipeline signals its stage transitions,
# failures and emitted artifacts into the shared scent field; compiled
# bytecode becomes content-addressed cache entries retrievable via signal
# URIs; perturbation testing gates builds with Mandelbrot `bounded` verdicts;
# and Zangbeto receipt quorums promote signals up the evidence-tier ladder.
#
# The bridge speaks plain JSON over HTTP to waggled (default :7777) and the
# fractal-oracle service (default :7778). All deposits flow through a
# registered *watch* so they carry evidence_tier "watch-derived": the compile
# log is the instrument reporting, not the interested party. Everything
# fails soft — a missing substrate never breaks a build, it just leaves no
# scent.

module WaggleBridge

using JSON
using SHA
using Dates
using Downloads

export ensure_watch, ingest!, stage!, compile_failed!, compile_emitted!
export cache_key, cache_put!, cache_get, compile_with_signals
export bounded_verdict!, perturb_and_verdict!, zangbeto_promote!
export regression_check, oracle_escape_risk

const WAGGLE = Ref(get(ENV, "WAGGLE_URL", "http://127.0.0.1:7777"))
const ORACLE = Ref(get(ENV, "FRACTAL_ORACLE_URL", "http://127.0.0.1:7778"))
const AGENT = "osovm"
const WATCH_ID = Ref{Union{String,Nothing}}(nothing)

# ---- plumbing --------------------------------------------------------------

function _request(method::String, url::String; body=nothing)
    buf = IOBuffer()
    input = body === nothing ? nothing : IOBuffer(JSON.json(body))
    headers = ["Content-Type" => "application/json"]
    try
        Downloads.request(url; method=method, input=input, output=buf,
                          headers=headers, throw=false)
        out = String(take!(buf))
        return isempty(out) ? nothing : JSON.parse(out)
    catch
        return nothing  # substrate absent: builds must not break
    end
end

_post(path, body) = _request("POST", WAGGLE[] * path; body=body)
_get(path) = _request("GET", WAGGLE[] * path)

# ---- watch: the compile log as instrument -----------------------------------

"""Register (once) the watch that turns ỌṢỌVM state transitions into
watch-derived deposits. Techgnosis lives in-process now, so this is a direct
call, not a webhook round-trip — one network hop to the field, none between
compiler and instrument."""
function ensure_watch()
    WATCH_ID[] === nothing || return WATCH_ID[]
    out = _post("/v1/watches", Dict(
        "agent" => AGENT,
        "name" => "osovm compile log",
        "resource_prefix" => "osovm://",
        "map" => Dict("success" => "gold", "failure" => "dead-end"),
    ))
    out === nothing && return nothing
    WATCH_ID[] = out["watch"]["id"]
    return WATCH_ID[]
end

"""Push one state transition through the watch. Returns the deposited signal
(or nothing when the field is unreachable). `cost` (a Dict with any of
`wall_clock_ms`/`dollars`/`tokens`) attaches the compute price of the
transition so cost-aware routing can prefer cheap-to-verify paths (§#4)."""
function ingest!(resource::String; outcome::String="", kind::String="",
                 subtype::String="", intensity::Real=0, note::String="",
                 meta::Dict=Dict(), cost::Union{Dict,Nothing}=nothing)
    id = ensure_watch()
    id === nothing && return nothing
    ev = Dict(
        "resource" => resource, "outcome" => outcome, "kind" => kind,
        "subtype" => subtype, "intensity" => intensity, "note" => note,
        "meta" => meta)
    cost === nothing || (ev["cost"] = cost)
    _post("/v1/ingest/$(id)", ev)
end

# ---- Techgnosis stage-transition signaling (§1.5, §1.6) ----------------------

"""Mark a pipeline stage transition (parsing → type-checking → codegen →
emitted) on the unit's URI. Stages ride the `explored` channel with the stage
as subtype, so a gradient over osovm:// shows where compilation activity is."""
stage!(uri::String, stage::String) =
    ingest!(uri; kind="explored", subtype=stage, intensity=1,
            note="techgnosis stage: $stage")

"""Compile failure: dead-end tagged with the failing stage, so successors
sniffing the unit see not just that it failed but *where*."""
compile_failed!(uri::String, stage::String, err) =
    ingest!(uri; outcome="failure", subtype=stage, intensity=4,
            note=first(string(err), 300))

"""Successful emit: gold on the unit, meta carrying the cache key so the
artifact is retrievable straight from the scent (§1.7). `compile_ms` (the
wall-clock the compile took) attaches as cost, so a cheap-to-build robust
path can be preferred over an expensive one when both are viable — the input
Yemọja's spawn decisions eventually weigh (§#4)."""
# cost provenance: OSOVM meters compile wall-clock (ms) only — no dollars, no
# tokens — so a cost-efficiency comparison against a LOOM signal is auditable to
# what each actually measured rather than trusted as a like-for-like number.
_compile_cost(compile_ms::Real) = compile_ms > 0 ?
    Dict("wall_clock_ms" => compile_ms,
         "source" => Dict("producer" => "osovm",
                          "method" => "compile-wall-clock",
                          "units" => "ms")) : nothing

compile_emitted!(uri::String, key::String; compile_ms::Real=0) =
    ingest!(uri; outcome="success", subtype="emitted", intensity=3,
            note="bytecode cached", meta=Dict("cache_key" => key),
            cost=_compile_cost(compile_ms))

# ---- bytecode cache keyed to signal URIs (§1.4, §1.7) ------------------------

"""Content address of a compilation unit: sha256 of the source. Identical
ritual computation → identical key → cache hit short-circuits recompute."""
cache_key(source::String) = bytes2hex(sha256(source))

"""Store compiled IR in Waggle's durable memory under the cache key and mark
gold on its URI: the field becomes a content-addressed build cache."""
function cache_put!(source::String, ir; compile_ms::Real=0)
    key = cache_key(source)
    _request("PUT", WAGGLE[] * "/v1/memory/osovm/bytecode/$(key)"; body=ir)
    compile_emitted!("osovm://bytecode/$(key)", key; compile_ms=compile_ms)
    return key
end

"""Sniff-before-compute: if a gold trail marks this key and the artifact is
in memory, return it and skip the whole pipeline."""
function cache_get(source::String)
    key = cache_key(source)
    sniffed = _get("/v1/sniff?resource=osovm://bytecode/$(key)&kind=gold")
    (sniffed === nothing || isempty(get(sniffed, "signals", []))) && return nothing
    out = _get("/v1/memory/osovm/bytecode/$(key)")
    out === nothing && return nothing
    return get(out, "value", nothing)
end

"""Compile with the full stigmergic pipeline: cache short-circuit, stage
signaling, dead-end on failure (tagged with the stage that broke), gold +
cache on success. `compile_fn` is the real compiler (e.g.
TechGnosCompiler.compile_tech); `uri` names the unit in the field."""
function compile_with_signals(compile_fn::Function, source::String, uri::String)
    cached = cache_get(source)
    cached !== nothing && return (cached, :cache_hit)
    current = "parsing"
    stage!(uri, current)
    t0 = time()
    try
        # the pipeline is one call; failures self-report their stage in the
        # error when possible, else the last stage we entered is blamed
        ir = compile_fn(source)
        current = "codegen"
        stage!(uri, current)
        # wall-clock of the whole compile becomes the emitted signal's cost
        key = cache_put!(source, ir; compile_ms=(time() - t0) * 1000)
        stage!(uri, "emitted")
        return (ir, :compiled)
    catch err
        compile_failed!(uri, current, err)
        rethrow()
    end
end

# ---- Mandelbrot build gate (§1.8) --------------------------------------------

"""Deposit a bounded verdict for a unit: stability ∈ [0,1] rides the shared
`bounded` channel as intensity 10·s. The channel's registration on the
substrate supplies the kernel, half-life, confidence-weighted alpha and
replace-mode reinforcement — the gate just reports the score."""
bounded_verdict!(uri::String, stability::Real; escape::Int=-1, maxiter::Int=-1,
                 verdict::String="") =
    ingest!(uri; kind="bounded", intensity=10 * clamp(stability, 0, 1),
            note=verdict,
            meta=Dict("escape" => string(escape), "maxiter" => string(maxiter),
                      "verdict" => verdict, "source" => "osovm-build-gate"))

"""The build-time perturbation gate: run compiled agent logic `f` over
`variations` jittered copies of `inputs` and measure whether behavior stays
on a robust island or escapes. An output is 'bounded' when it stays within
`tolerance` (relative) of the unperturbed output; stability is the bounded
fraction — the same score the fractal-oracle's swarm_stability_map produces,
deposited on the same channel. Fragile bytecode gets flagged before it is
ever deployed."""
function perturb_and_verdict!(f::Function, uri::String, inputs::Vector{Float64};
                              variations::Int=12, jitter::Float64=0.01,
                              tolerance::Float64=0.25)
    base = try
        f(inputs)
    catch
        bounded_verdict!(uri, 0.0; verdict="escape zone")
        return 0.0
    end
    bounded = 0
    for i in 1:variations
        jittered = [x * (1 + jitter * (2 * rand() - 1)) for x in inputs]
        ok = try
            out = f(jittered)
            ref = abs(float(base)) > eps() ? abs(float(base)) : 1.0
            abs(float(out) - float(base)) / ref <= tolerance
        catch
            false
        end
        bounded += ok ? 1 : 0
    end
    s = bounded / variations
    verdict = s >= 1.0 ? "robust island" : (s > 0.5 ? "fragile boundary" : "escape zone")
    bounded_verdict!(uri, s; escape=bounded, maxiter=variations, verdict=verdict)
    return s
end

"""Ask the shared fractal-oracle service for a point verdict (the ecosystem
source of truth; Axiom's embedded Wasm copy is for offline use). Returns the
parsed result or nothing when the oracle is down."""
oracle_escape_risk(re::Real, im::Real; depth::Int=2) =
    _request("GET", ORACLE[] * "/v1/escape_time_risk?re=$(re)&im=$(im)&depth=$(depth)")

# ---- Zangbeto → evidence tier promotion (§1.2, §1.9) --------------------------

"""A Zangbeto receipt that clears its witness quorum promotes the unit's
signal up the trust ladder: re-deposited at `zangbeto-verified`, one step
below on-chain anchoring. Promotion is a new deposit, never a rewrite —
the journal keeps the whole ladder climb."""
function zangbeto_promote!(uri::String; receipt_id::String="",
                           robustness::Union{Nothing,Real}=nothing,
                           passed::Bool=true)
    passed || return ingest!(uri; outcome="failure", subtype="zangbeto",
                             note="receipt failed quorum",
                             meta=Dict("receipt" => receipt_id))
    sig = _post("/v1/signals", Dict(
        "agent" => AGENT, "resource" => uri, "kind" => "gold",
        "intensity" => 5, "evidence_tier" => "zangbeto-verified",
        "note" => "zangbeto receipt verified (7/12 quorum)",
        "meta" => Dict("receipt" => receipt_id)))
    if robustness !== nothing
        _post("/v1/signals", Dict(
            "agent" => AGENT, "resource" => uri, "kind" => "bounded",
            "intensity" => 10 * clamp(robustness, 0, 1),
            "evidence_tier" => "zangbeto-verified",
            "meta" => Dict("receipt" => receipt_id, "source" => "zangbeto")))
    end
    return sig
end

# ---- recall-backed regression detection (§1.10) -------------------------------

"""Before shipping a build: compare the unit's bounded verdict now against
the journal's state `hours_ago`. Returns (then, now, rsi) where rsi is
stability lost per half-life — a build that silently turns previously-robust
logic brittle shows up as rsi > 0.5 and should be blocked. Requires waggled
to run with -data; returns nothing without a journal."""
function regression_check(uri::String; hours_ago::Real=24, half_life_s::Real=7200)
    at = string(Dates.now(Dates.UTC) - Dates.Hour(round(Int, hours_ago)), "Z")
    past = _get("/v1/recall?resource=$(uri)&kind=bounded&at=$(at)")
    now_sigs = _get("/v1/sniff?resource=$(uri)&kind=bounded")
    (past === nothing || now_sigs === nothing) && return nothing
    s_then = isempty(get(past, "signals", [])) ? nothing :
             past["signals"][1]["intensity"] / 10
    s_now = isempty(get(now_sigs, "signals", [])) ? nothing :
            now_sigs["signals"][1]["intensity"] / 10
    (s_then === nothing || s_now === nothing) && return nothing
    dt = hours_ago * 3600
    rsi = (s_then - s_now) * (half_life_s / dt)
    return (then=s_then, now=s_now, rsi=rsi, regressed=rsi > 0.5)
end

end # module
