#!/usr/bin/env julia
# test/runtests.jl — OSOVM full test suite entry point
#
# Each test file includes its own source modules directly, so they cannot
# safely share a process.  We spawn a subprocess per file and aggregate results.
#
# Usage:
#   julia --project=. test/runtests.jl          # run all tests
#   julia --project=. test/runtests.jl fast      # skip benchmarks
#   make test                                    # alias for the above

using Dates

const TEST_DIR = joinpath(@__DIR__)

# Benchmarks are slow and non-deterministic by design — skip in fast mode
const SKIP_IN_FAST = Set(["veil_benchmarks.jl"])

# Tests that require network/external services — skip in offline CI
const SKIP_OFFLINE = Set([
    "nostr_bridge_test.jl",
    "vantage_bridge_test.jl",
    "seal_bridge_test.jl",
])

# Determinism tests are run by a dedicated CI job (arm-determinism.yml)
const SKIP_DETERMINISM = Set([
    "determinism_real.jl",
    "veilsim_engine_determinism_test.jl",
    "gate4_contact_determinism_test.jl",
])

all_test_files = sort(filter(f -> endswith(f, ".jl") && f != "runtests.jl",
                             readdir(TEST_DIR)))

fast_mode   = "fast"   in ARGS
offline     = get(ENV, "CI", "false") == "true" || "offline" in ARGS
skip_det    = get(ENV, "SKIP_DETERMINISM", "false") == "true"

skipped = Set{String}()
if fast_mode;   union!(skipped, SKIP_IN_FAST) end
if offline;     union!(skipped, SKIP_OFFLINE) end
if skip_det;    union!(skipped, SKIP_DETERMINISM) end

pass_list  = String[]
fail_list  = Tuple{String,String}[]   # (file, reason)
skip_list  = String[]

total_start = now()
println("=" ^ 72)
println("  OSOVM Test Suite   $(Dates.format(total_start, "yyyy-mm-dd HH:MM:SS"))")
println("  $(length(all_test_files)) test files  |  fast=$fast_mode  offline=$offline")
println("=" ^ 72)

for fname in all_test_files
    path = joinpath(TEST_DIR, fname)
    pad  = rpad(fname, 48)

    if fname in skipped
        println("  SKIP  $fname")
        push!(skip_list, fname)
        continue
    end

    t0 = time()
    # Run in a clean subprocess so module re-definitions don't accumulate
    result = run(ignorestatus(`julia --project=$(joinpath(TEST_DIR, "..")) $path`))
    elapsed = round(time() - t0, digits=1)

    if result.exitcode == 0
        println("  PASS  $pad  $(elapsed)s")
        push!(pass_list, fname)
    else
        println("  FAIL  $pad  exit=$(result.exitcode)  $(elapsed)s")
        push!(fail_list, (fname, "exit $(result.exitcode)"))
    end
end

elapsed_total = round((now() - total_start).value / 1000, digits=1)
println("=" ^ 72)
println("  PASS=$(length(pass_list))  FAIL=$(length(fail_list))  SKIP=$(length(skip_list))  total=$(elapsed_total)s")
println("=" ^ 72)

if !isempty(fail_list)
    println("\nFailing tests:")
    for (f, reason) in fail_list
        println("  ✗  $f  ($reason)")
    end
    exit(1)
else
    println("\n✅ All $(length(pass_list)) tests passed.  Àṣẹ.")
    exit(0)
end
