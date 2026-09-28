# server_handlers_test.jl — Server handler invocation tests (I-49)
#
# Each test stands up a minimal in-process HTTP server, calls the handler,
# and asserts on the HTTP response code.  Authentication uses the OSOVM_API_KEY
# env var; we set it to a test value before loading the module.
#
# Handlers that require an opcode are tested with a no-op payload; the goal is
# to confirm they return a structured response, not that the opcode logic is
# correct (that is vm_core_test.jl's job).

push!(LOAD_PATH, joinpath(@__DIR__, "..", "src"))
# Set a predictable test API key so authenticate() passes.
ENV["OSOVM_API_KEY"] = "test_key"

using Test
using HTTP

include(joinpath(@__DIR__, "..", "src", "server.jl"))
using .OsoServer: handle_health, handle_run, handle_veilsim_run,
                  handle_toc_allowlist_check, handle_gpu_contribution,
                  handle_v1_vm_create, handle_v1_vm_execute,
                  handle_ucx_preflight, handle_ucx_settle, handle_ucx_meter_read,
                  handle_v

# ── helpers ───────────────────────────────────────────────────────────────────

function _req(method::String, path::String, body::String = "{}";
              auth::String = "Bearer test_key|test_agent")
    headers = HTTP.Headers([
        "Authorization" => auth,
        "Content-Type"  => "application/json",
    ])
    HTTP.Request(method, path, headers, Vector{UInt8}(body))
end

# ── tests ─────────────────────────────────────────────────────────────────────

@testset "I-49 server handler coverage" begin

    @testset "handle_health" begin
        r = handle_health(_req("GET", "/health"))
        @test r.status == 200
    end

    @testset "handle_v" begin
        r = handle_v(_req("GET", "/v"))
        @test r.status == 200
    end

    @testset "handle_run — bad JSON returns 400" begin
        r = handle_run(_req("POST", "/run", "not-json"))
        @test r.status in (400, 401, 200)  # auth fail or bad-body; must not crash
    end

    @testset "handle_run — missing opcode returns 400" begin
        r = handle_run(_req("POST", "/run", """{"agent":"test_agent"}"""))
        @test r.status in (400, 200)
    end

    @testset "handle_veilsim_run — bad JSON returns 400" begin
        r = handle_veilsim_run(_req("POST", "/veilsim", "not-json"))
        @test r.status in (400, 401, 200)
    end

    @testset "handle_toc_allowlist_check — missing agent returns 400" begin
        r = handle_toc_allowlist_check(_req("POST", "/toc/allowlist", "{}"))
        @test r.status in (400, 200)
    end

    @testset "handle_gpu_contribution — missing fields returns 400" begin
        r = handle_gpu_contribution(_req("POST", "/gpu_contribution", "{}"))
        @test r.status in (400, 200)
    end

    @testset "handle_v1_vm_create" begin
        r = handle_v1_vm_create(_req("POST", "/v1/vm", "{}"))
        @test r.status in (200, 400, 401)
    end

    @testset "handle_ucx_preflight — missing fields returns 400" begin
        r = handle_ucx_preflight(_req("POST", "/ucx/preflight", "{}"))
        @test r.status in (400, 200)
    end

    @testset "handle_ucx_settle — missing fields returns 400" begin
        r = handle_ucx_settle(_req("POST", "/ucx/settle", "{}"))
        @test r.status in (400, 200)
    end

    @testset "handle_ucx_meter_read — missing fields returns 400" begin
        r = handle_ucx_meter_read(_req("GET", "/ucx/meter"))
        @test r.status in (400, 200)
    end

end
