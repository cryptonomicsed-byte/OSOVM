#!/usr/bin/env julia
# server_main.jl — start OSOVM HTTP server
# Usage: julia --project=. src/server_main.jl
include("server.jl")
using .OsoVMServer
OsoVMServer.start()
