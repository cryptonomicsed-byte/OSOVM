# World Tiles — Spatial Partitioning + Sim Library for Speculative Economy
# Humans create simulations that agents consume. Tiles index the world.
# Crown Architect: Bino EL Gua Omo Koda Ase

module WorldTiles

using Dates
using SHA
using Statistics

export WorldTile, SimRecord, SimLibrary
export create_tile, tile_key, tiles_in_range
export submit_simulation, query_simulations, consume_simulation, query_by_veil
export compute_sim_value, library_stats

# ============================================================================
# 1. WORLD TILE — Spatial Index
# ============================================================================

"""
World is divided into tiles on a [layer, x, z] grid.
Each tile is 100m x 100m at layer 0 (ground), with vertical layers.
Tile coordinates are integers; position maps to tile via floor division.
"""
struct WorldTile
    layer::Int      # Vertical layer (0=ground, 1=low-air, 2=high-air, etc.)
    x::Int          # East-West grid coordinate
    z::Int          # North-South grid coordinate
end

const TILE_SIZE = 100.0  # meters per tile edge

function create_tile(layer::Int, x::Int, z::Int)::WorldTile
    WorldTile(layer, x, z)
end

function tile_key(tile::WorldTile)::String
    "$(tile.layer):$(tile.x):$(tile.z)"
end

function position_to_tile(px::Float64, py::Float64, pz::Float64)::WorldTile
    layer = max(0, floor(Int, py / TILE_SIZE))
    x = floor(Int, px / TILE_SIZE)
    z = floor(Int, pz / TILE_SIZE)
    WorldTile(layer, x, z)
end

function tiles_in_range(center::WorldTile, radius::Int)::Vector{WorldTile}
    tiles = WorldTile[]
    for l in max(0, center.layer - radius):(center.layer + radius)
        for x in (center.x - radius):(center.x + radius)
            for z in (center.z - radius):(center.z + radius)
                push!(tiles, WorldTile(l, x, z))
            end
        end
    end
    tiles
end

# ============================================================================
# 2. SIM RECORD — A Cached Simulation Result
# ============================================================================

"""
A simulation record stored in the Sim Library.
Created by humans (or agents), consumed by agents for real-world execution.
"""
mutable struct SimRecord
    sim_id::String
    creator_wallet::String       # Who created it (human or agent)
    created_at::DateTime

    # Spatial scope
    origin_tile::WorldTile
    destination_tile::WorldTile
    tiles_covered::Vector{WorldTile}

    # Simulation data
    veil_ids::Vector{Int}        # Which veils were used
    entity_count::Int
    step_count::Int
    f1_score::Float64
    energy_drift::Float64
    robustness::Float64

    # Trajectory data (compressed)
    trajectory_hash::String      # SHA-256 of full trajectory
    trajectory_checkpoints::Vector{Dict{String,Any}}  # Sampled waypoints

    # Economy
    ase_cost::Float64            # Cost to create (7.77 base)
    ase_earned::Float64          # Total Ase earned from consumption
    consumption_count::Int       # How many agents consumed this
    multiplier::Float64          # 2x for consumed sims

    # Anchoring
    chain_anchors::Dict{String,String}

    # Status
    status::String               # "pending", "validated", "expired", "consumed"
    expires_at::DateTime
end

# ============================================================================
# 3. SIM LIBRARY — The Marketplace
# ============================================================================

"""
The Sim Library is the marketplace where simulations are stored, indexed by
tile, and queried by agents needing physics-validated trajectories.
"""
mutable struct SimLibrary
    records::Dict{String, SimRecord}        # sim_id -> record
    tile_index::Dict{String, Vector{String}} # tile_key -> [sim_ids]
    veil_index::Dict{Int, Vector{String}}   # veil_id -> [sim_ids]

    total_ase_minted::Float64
    total_ase_consumed::Float64
    total_simulations::Int
    total_consumptions::Int

    f1_threshold::Float64        # Minimum F1 to accept into library
    expiry_days::Int             # Days before sim expires
end

function SimLibrary(;f1_threshold::Float64=0.777, expiry_days::Int=49)::SimLibrary
    SimLibrary(
        Dict{String, SimRecord}(),
        Dict{String, Vector{String}}(),
        Dict{Int, Vector{String}}(),
        0.0, 0.0, 0, 0,
        f1_threshold,
        expiry_days
    )
end

# ============================================================================
# 4. SUBMIT — Humans/Agents Create Simulations
# ============================================================================

const BASE_SIM_COST = 7.77       # Ase cost to create a sim
const CONSUMPTION_MULTIPLIER = 2.0 # Creator earns 2x when consumed

function submit_simulation(
    library::SimLibrary,
    sim_id::String,
    creator_wallet::String,
    origin_tile::WorldTile,
    destination_tile::WorldTile,
    veil_ids::Vector{Int},
    entity_count::Int,
    step_count::Int,
    f1_score::Float64,
    energy_drift::Float64,
    robustness::Float64,
    trajectory_checkpoints::Vector{Dict{String,Any}},
    chain_anchors::Dict{String,String}
)::Union{SimRecord, Nothing}

    # Reject if F1 below threshold
    if f1_score < library.f1_threshold
        println("[SimLibrary] REJECTED: F1=$(round(f1_score, digits=3)) < threshold=$(library.f1_threshold)")
        return nothing
    end

    # Compute tiles covered (line between origin and destination)
    covered = compute_tile_path(origin_tile, destination_tile)

    # Trajectory hash
    traj_data = join([string(cp) for cp in trajectory_checkpoints], "|")
    traj_hash = bytes2hex(sha256(traj_data))

    record = SimRecord(
        sim_id,
        creator_wallet,
        now(),
        origin_tile,
        destination_tile,
        covered,
        veil_ids,
        entity_count,
        step_count,
        f1_score,
        energy_drift,
        robustness,
        traj_hash,
        trajectory_checkpoints,
        BASE_SIM_COST,
        0.0,
        0,
        CONSUMPTION_MULTIPLIER,
        chain_anchors,
        "validated",
        now() + Day(library.expiry_days)
    )

    # Store in library
    library.records[sim_id] = record
    library.total_simulations += 1
    library.total_ase_minted += BASE_SIM_COST

    # Index by tiles
    for tile in covered
        tk = tile_key(tile)
        if !haskey(library.tile_index, tk)
            library.tile_index[tk] = String[]
        end
        push!(library.tile_index[tk], sim_id)
    end

    # Index by veils
    for vid in veil_ids
        if !haskey(library.veil_index, vid)
            library.veil_index[vid] = String[]
        end
        push!(library.veil_index[vid], sim_id)
    end

    println("[SimLibrary] ACCEPTED: $(sim_id) | F1=$(round(f1_score, digits=3)) | Tiles=$(length(covered)) | Cost=$(BASE_SIM_COST) Ase")
    return record
end

# ============================================================================
# 5. QUERY — Agents Search for Simulations
# ============================================================================

"""
Query simulations covering a tile path. Returns sorted by F1 score descending.
"""
function query_simulations(
    library::SimLibrary,
    origin_tile::WorldTile,
    destination_tile::WorldTile;
    min_f1::Float64 = 0.0,
    max_results::Int = 10
)::Vector{SimRecord}

    # Find all sims that cover both origin and destination tiles
    origin_key = tile_key(origin_tile)
    dest_key = tile_key(destination_tile)

    origin_sims = get(library.tile_index, origin_key, String[])
    dest_sims = get(library.tile_index, dest_key, String[])

    # Intersection
    candidates = intersect(Set(origin_sims), Set(dest_sims))

    results = SimRecord[]
    for sim_id in candidates
        record = library.records[sim_id]
        if record.status == "validated" && record.f1_score >= min_f1 && record.expires_at > now()
            push!(results, record)
        end
    end

    # Sort by F1 descending
    sort!(results, by=r -> -r.f1_score)

    return results[1:min(max_results, length(results))]
end

"""
Query simulations by veil ID.
"""
function query_by_veil(
    library::SimLibrary,
    veil_id::Int;
    min_f1::Float64 = 0.0,
    max_results::Int = 10
)::Vector{SimRecord}

    sim_ids = get(library.veil_index, veil_id, String[])

    results = SimRecord[]
    for sim_id in sim_ids
        record = library.records[sim_id]
        if record.status == "validated" && record.f1_score >= min_f1 && record.expires_at > now()
            push!(results, record)
        end
    end

    sort!(results, by=r -> -r.f1_score)
    return results[1:min(max_results, length(results))]
end

# ============================================================================
# 6. CONSUME — Agents Use Simulations
# ============================================================================

"""
Agent consumes a simulation. Creator earns 2x Ase multiplier.
Returns trajectory checkpoints for real-world execution.
"""
function consume_simulation(
    library::SimLibrary,
    sim_id::String,
    consumer_wallet::String
)::Union{Vector{Dict{String,Any}}, Nothing}

    if !haskey(library.records, sim_id)
        println("[SimLibrary] NOT FOUND: $sim_id")
        return nothing
    end

    record = library.records[sim_id]

    if record.status != "validated"
        println("[SimLibrary] NOT AVAILABLE: $sim_id (status=$(record.status))")
        return nothing
    end

    if record.expires_at <= now()
        record.status = "expired"
        println("[SimLibrary] EXPIRED: $sim_id")
        return nothing
    end

    # Record consumption
    record.consumption_count += 1
    ase_reward = BASE_SIM_COST * record.multiplier
    record.ase_earned += ase_reward

    library.total_consumptions += 1
    library.total_ase_consumed += ase_reward

    println("[SimLibrary] CONSUMED: $sim_id by $consumer_wallet | Creator earns $(round(ase_reward, digits=2)) Ase ($(record.consumption_count)x consumed)")

    return record.trajectory_checkpoints
end

# ============================================================================
# 7. TILE PATH COMPUTATION
# ============================================================================

"""
Compute tiles along the path from origin to destination using Bresenham-like
3D line algorithm on the tile grid.
"""
function compute_tile_path(origin::WorldTile, dest::WorldTile)::Vector{WorldTile}
    tiles = WorldTile[]

    dx = dest.x - origin.x
    dy = dest.layer - origin.layer
    dz = dest.z - origin.z

    steps = max(abs(dx), abs(dy), abs(dz), 1)

    for i in 0:steps
        t = i / steps
        l = round(Int, origin.layer + dy * t)
        x = round(Int, origin.x + dx * t)
        z = round(Int, origin.z + dz * t)
        tile = WorldTile(max(0, l), x, z)
        if isempty(tiles) || tiles[end] != tile
            push!(tiles, tile)
        end
    end

    tiles
end

# ============================================================================
# 8. ECONOMICS & STATISTICS
# ============================================================================

"""
Compute the economic value of a simulation based on F1, consumption, and age.
"""
function compute_sim_value(record::SimRecord)::Float64
    # Base value from F1
    f1_value = record.f1_score * BASE_SIM_COST

    # Consumption bonus
    consumption_bonus = record.consumption_count * BASE_SIM_COST * 0.5

    # Age decay (linear over expiry period)
    age_days = Dates.value(now() - record.created_at) / (1000 * 60 * 60 * 24)
    age_factor = max(0.0, 1.0 - age_days / 49.0)

    return (f1_value + consumption_bonus) * age_factor
end

function library_stats(library::SimLibrary)::Dict{String,Any}
    active = count(r -> r.status == "validated" && r.expires_at > now(), values(library.records))
    avg_f1 = if library.total_simulations > 0
        mean(r.f1_score for r in values(library.records))
    else
        0.0
    end

    Dict(
        "total_simulations" => library.total_simulations,
        "active_simulations" => active,
        "total_consumptions" => library.total_consumptions,
        "total_ase_minted" => library.total_ase_minted,
        "total_ase_consumed" => library.total_ase_consumed,
        "average_f1" => avg_f1,
        "unique_tiles_indexed" => length(library.tile_index),
        "unique_veils_indexed" => length(library.veil_index)
    )
end

end # module WorldTiles
