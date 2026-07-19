# OsoVM.jl -- package entry point required by Julia's Pkg convention
# (src/<PackageName>.jl must match the `name` field in Project.toml exactly).
# The real implementation lives in oso_vm.jl; this just re-exposes it so
# Pkg.instantiate()/`using OsoVM` work without disturbing the existing
# direct include("oso_vm.jl") pattern the test suite already relies on.
# Base.include(@__MODULE__, ...) (not bare include) is required under
# Julia 1.11's package precompilation, which runs entry files in a
# restricted top-level scope that doesn't expose plain `include`.
Base.include(@__MODULE__, "oso_vm.jl")
