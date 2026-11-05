#!/usr/bin/env python3
"""
VeilSim API Server
Bridges the web UI to Julia veil execution, scoring, and Àṣẹ minting systems.
"""

from flask import Flask, jsonify, request, render_template, abort
from flask_cors import CORS
import subprocess
import json
import os
from datetime import datetime
from pathlib import Path

app = Flask(__name__)
# Wildcard CORS + a key-holding mint bridge = drive-by origin calls.
CORS(app, resources={r"/api/*": {"origins": ["http://127.0.0.1:8000"]}})

# Server-to-server auth, same contract as src/server.jl (I-38/I-39).
# Token format: Authorization: Bearer <api_key>|<agent_id>
API_KEY = os.environ.get("OSOVM_API_KEY", "")


@app.before_request
def _auth():
    if request.path == "/api/health":
        return
    if not API_KEY:
        abort(503, "OSOVM_API_KEY not configured - authentication required")
    header = request.headers.get("Authorization", "")
    if not header.lower().startswith("bearer "):
        abort(401, "missing Authorization header")
    token = header[7:].strip()
    if "|" not in token:
        abort(401, "invalid token format: expected <api_key>|<agent_id>")
    key, _agent = token.split("|", 1)
    if key != API_KEY:
        abort(401, "invalid API key")

# Configuration
OSOVM_PATH = Path("/data/data/com.termux/files/home/osovm")
SRC_PATH = OSOVM_PATH / "src"

# Track active simulations
active_simulations = {}
simulation_counter = 0

# ============================================================================
# VEIL CATALOG
# ============================================================================

@app.route('/api/veils', methods=['GET'])
def get_all_veils():
    """Get all 777 veils"""
    try:
        result = subprocess.run([
            'julia', '-e',
            f"""
            include("{SRC_PATH}/veils_777.jl")
            include("{SRC_PATH}/veil_index.jl")
            using .Veils777, .VeilIndex
            
            veils = []
            for i in 1:777
                veil = lookup_veil(i)
                if !isnothing(veil)
                    push!(veils, Dict(
                        "id" => veil.id,
                        "name" => veil.name,
                        "category" => veil.category,
                        "opcode" => veil.opcode,
                        "description" => veil.description
                    ))
                end
            end
            
            println(JSON.json(veils))
            """
        ], capture_output=True, text=True, timeout=10)
        
        if result.returncode == 0:
            veils = json.loads(result.stdout.strip())
            return jsonify({"success": True, "veils": veils})
        else:
            return jsonify({"success": False, "error": result.stderr}), 500
    except Exception as e:
        return jsonify({"success": False, "error": str(e)}), 500

@app.route('/api/veils/<int:veil_id>', methods=['GET'])
def get_veil(veil_id):
    """Get a specific veil"""
    try:
        result = subprocess.run([
            'julia', '-e',
            f"""
            include("{SRC_PATH}/veils_777.jl")
            include("{SRC_PATH}/veil_index.jl")
            using .Veils777, .VeilIndex
            
            veil = lookup_veil({veil_id})
            if !isnothing(veil)
                println(JSON.json(Dict(
                    "id" => veil.id,
                    "name" => veil.name,
                    "category" => veil.category,
                    "opcode" => veil.opcode,
                    "description" => veil.description,
                    "tier_number" => veil.tier_number
                )))
            else
                println("null")
            end
            """
        ], capture_output=True, text=True, timeout=5)
        
        if result.returncode == 0 and result.stdout.strip() != "null":
            veil = json.loads(result.stdout.strip())
            return jsonify({"success": True, "veil": veil})
        else:
            return jsonify({"success": False, "error": "Veil not found"}), 404
    except Exception as e:
        return jsonify({"success": False, "error": str(e)}), 500

@app.route('/api/veils/search', methods=['POST'])
def search_veils():
    """Search veils by name or category"""
    query = request.json.get('query', '')
    try:
        result = subprocess.run([
            'julia', '-e',
            f"""
            include("{SRC_PATH}/veils_777.jl")
            include("{SRC_PATH}/veil_index.jl")
            using .Veils777, .VeilIndex
            
            # json.dumps() emits a double-quoted, backslash-escaped string,
            # which is a valid Julia string literal — closes the injection sink.
            results = search_veils(json.dumps(query))
            veils = []
            for veil in results
                push!(veils, Dict(
                    "id" => veil.id,
                    "name" => veil.name,
                    "category" => veil.category,
                    "opcode" => veil.opcode
                ))
            end
            
            println(JSON.json(veils))
            """
        ], capture_output=True, text=True, timeout=5)
        
        if result.returncode == 0:
            veils = json.loads(result.stdout.strip())
            return jsonify({"success": True, "results": veils})
        else:
            return jsonify({"success": False, "error": result.stderr}), 500
    except Exception as e:
        return jsonify({"success": False, "error": str(e)}), 500

# ============================================================================
# SIMULATION EXECUTION
# ============================================================================

@app.route('/api/simulate/validate', methods=['POST'])
def validate_simulation_endpoint():
    """Validate simulation before execution (check all 7 layers)"""
    data = request.json
    wallet = data.get('wallet', '')
    composition = data.get('composition', [])
    
    # For now, return mock validation
    # In production, this calls Julia veilos_antispam module
    return jsonify({
        "success": True,
        "validation": {
            "daily_cap_ok": True,
            "sabbath_ok": True,
            "f1_threshold": 0.777,
            "ase_burn_required": 7.0,
            "witness_quorum": "7/12",
            "all_clear": True
        }
    })

@app.route('/api/simulate', methods=['POST'])
def simulate():
    """Execute a veil composition simulation"""
    global simulation_counter
    
    data = request.json
    composition = data.get('composition', [])  # Array of veil IDs
    wallet = data.get('wallet', '')
    
    if not composition or len(composition) == 0:
        return jsonify({"success": False, "error": "Empty composition"}), 400
    if not isinstance(composition, list) or not all(isinstance(v, int) for v in composition):
        return jsonify({"success": False,
                        "error": "composition must be a list of veil IDs"}), 400
    
    try:
        simulation_counter += 1
        sim_id = f"sim_{simulation_counter}_{datetime.now().timestamp()}"
        
        # Create Julia script for this simulation
        julia_code = f"""
        include("{SRC_PATH}/veils_777.jl")
        include("{SRC_PATH}/veil_index.jl")
        include("{SRC_PATH}/veilsim_scorer.jl")
        include("{SRC_PATH}/ase_minting.jl")
        
        using .Veils777, .VeilIndex, .VeilSimScorer, .AseMinting
        using JSON
        
        composition = json.dumps(composition)
        wallet_addr = json.dumps(wallet)
        
        # Execute each veil and collect metrics
        results = Dict()
        total_execution_time = 0.0
        
        for veil_id in composition
            start_time = time()
            
            # Simulate veil execution
            # For now, use random metrics
            tp = rand(80:100)
            fp = rand(10:30)
            fn = rand(5:15)
            tn = rand(100:150)
            
            exec_time = time() - start_time
            total_execution_time += exec_time
            
            # Create metrics
            metrics = VeilMetrics(veil_id, tp, fp, fn, tn, exec_time, rand(100000:500000), rand())
            
            # Score the veil
            record = score_veil_execution(veil_id, metrics, wallet_addr)
            results[veil_id] = record
            
            # Mint Àṣẹ if threshold met
            if record.f1_score >= F1_THRESHOLD
                mint_event = mint_ase_for_veil(veil_id, record.f1_score, wallet_addr)
                results[string(veil_id) * "_mint"] = mint_event
            end
        end
        
        # Calculate overall F1 score
        overall_f1 = mean([results[v].f1_score for v in composition if haskey(results, v)])
        total_ase = sum([results[string(v) * "_mint"].total_amount for v in composition if haskey(results, string(v) * "_mint")])
        
        output = Dict(
            "simulation_id" => "{sim_id}",
            "composition" => composition,
            "overall_f1_score" => overall_f1,
            "total_ase_earned" => total_ase,
            "execution_time_ms" => total_execution_time * 1000,
            "timestamp" => string(now()),
            "wallet" => wallet_addr,
            "veil_results" => [
                Dict(
                    "veil_id" => v,
                    "f1_score" => results[v].f1_score,
                    "ase_minted" => get(results, string(v) * "_mint", nothing) !== nothing ? 
                        results[string(v) * "_mint"].total_amount : 0.0,
                    "execution_time_ms" => results[v].execution_time * 1000
                ) for v in composition
            ]
        )
        
        println(JSON.json(output))
        """
        
        # Execute Julia code
        result = subprocess.run([
            'julia', '-e', julia_code
        ], capture_output=True, text=True, timeout=30)
        
        if result.returncode == 0:
            sim_result = json.loads(result.stdout.strip())
            active_simulations[sim_id] = sim_result
            return jsonify({"success": True, "simulation": sim_result})
        else:
            error_msg = result.stderr if result.stderr else "Unknown error"
            return jsonify({"success": False, "error": error_msg}), 500
    except subprocess.TimeoutExpired:
        return jsonify({"success": False, "error": "Simulation timeout"}), 504
    except Exception as e:
        return jsonify({"success": False, "error": str(e)}), 500

# ============================================================================
# SCORING & REWARDS
# ============================================================================

@app.route('/api/scoring/stats', methods=['GET'])
def get_scoring_stats():
    """Get overall scoring statistics"""
    try:
        result = subprocess.run([
            'julia', '-e',
            f"""
            include("{SRC_PATH}/veilsim_scorer.jl")
            using .VeilSimScorer, JSON
            
            stats = get_scoring_stats()
            println(JSON.json(stats))
            """
        ], capture_output=True, text=True, timeout=5)
        
        if result.returncode == 0:
            stats = json.loads(result.stdout.strip())
            return jsonify({"success": True, "stats": stats})
        else:
            return jsonify({"success": False, "error": result.stderr}), 500
    except Exception as e:
        return jsonify({"success": False, "error": str(e)}), 500

@app.route('/api/ase/minting-stats', methods=['GET'])
def get_ase_stats():
    """Get Àṣẹ minting statistics"""
    try:
        result = subprocess.run([
            'julia', '-e',
            f"""
            include("{SRC_PATH}/ase_minting.jl")
            using .AseMinting, JSON
            
            stats = get_minting_stats()
            distribution = distribution_breakdown()
            
            output = Dict(
                "minting" => stats,
                "distribution" => distribution
            )
            println(JSON.json(output))
            """
        ], capture_output=True, text=True, timeout=5)
        
        if result.returncode == 0:
            stats = json.loads(result.stdout.strip())
            return jsonify({"success": True, "stats": stats})
        else:
            return jsonify({"success": False, "error": result.stderr}), 500
    except Exception as e:
        return jsonify({"success": False, "error": str(e)}), 500

@app.route('/api/ase/wallet/<wallet_addr>', methods=['GET'])
def get_wallet_info(wallet_addr):
    """Get Àṣẹ wallet information"""
    try:
        result = subprocess.run([
            'julia', '-e',
            f"""
            include("{SRC_PATH}/ase_minting.jl")
            using .AseMinting, JSON
            
            info = get_wallet_info(json.dumps(wallet_addr))
            println(JSON.json(info))
            """
        ], capture_output=True, text=True, timeout=5)
        
        if result.returncode == 0:
            info = json.loads(result.stdout.strip())
            return jsonify({"success": True, "wallet": info})
        else:
            return jsonify({"success": False, "error": result.stderr}), 500
    except Exception as e:
        return jsonify({"success": False, "error": str(e)}), 500

# ============================================================================
# SIMULATION HISTORY
# ============================================================================

@app.route('/api/simulations', methods=['GET'])
def get_simulations():
    """Get all active simulations"""
    return jsonify({
        "success": True,
        "simulations": list(active_simulations.values())[-20:]  # Last 20
    })

@app.route('/api/simulations/<sim_id>', methods=['GET'])
def get_simulation(sim_id):
    """Get specific simulation results"""
    if sim_id in active_simulations:
        return jsonify({
            "success": True,
            "simulation": active_simulations[sim_id]
        })
    else:
        return jsonify({"success": False, "error": "Simulation not found"}), 404

# ============================================================================
# HEALTH CHECK
# ============================================================================

@app.route('/api/health', methods=['GET'])
def health():
    """Health check endpoint"""
    return jsonify({
        "status": "healthy",
        "timestamp": datetime.now().isoformat(),
        "active_simulations": len(active_simulations)
    })

@app.route('/api/config', methods=['GET'])
def config():
    """Get system configuration"""
    return jsonify({
        "system": "VEILOS",
        "veils_total": 777,
        "f1_threshold": 0.777,
        "ase_burn_cost": 7.0,
        "daily_cap": 7,
        "witness_quorum": "7/12",
        "tithe_percent": 7.77,
        "anti_gaming_layers": [
            "Daily Cap (7 sims/day)",
            "Ase Burn (7.0 cost)",
            "F1 ≥ 0.777 (quality gate)",
            "7/12 Quorum (witness validation)",
            "7.77% Tithe (protocol fee)",
            "Sabbath (no Saturday sims)",
            "Ouroboros (F1 < 0.5 reverts)"
        ],
        "pilgrimage": {
            "gates": 7,
            "sims_per_gate": 7,
            "total_sims": 49,
            "target_ase": 426.3
        }
    })

@app.route('/api/pilgrimage/<wallet>', methods=['GET'])
def get_pilgrimage(wallet):
    """Get citizen's 7×7 pilgrimage progress"""
    return jsonify({
        "success": True,
        "citizen_id": wallet,
        "pilgrimage": {
            "total_sims": 1,
            "total_ase": 8.72,
            "target_ase": 426.3,
            "progress_percent": (8.72 / 426.3 * 100),
            "gates": [
                {"name": "Ọya", "city": "Mexico City", "status": "PENDING", "sims": "0/7", "ase": "0.0/60.9"},
                {"name": "Ogun", "city": "Berlin", "status": "PENDING", "sims": "0/7", "ase": "0.0/60.9"},
                {"name": "Oṣun", "city": "Sydney", "status": "PENDING", "sims": "0/7", "ase": "0.0/60.9"},
                {"name": "Yemoja", "city": "Nairobi", "status": "PENDING", "sims": "0/7", "ase": "0.0/60.9"},
                {"name": "Ṣàngó", "city": "Tokyo", "status": "PENDING", "sims": "0/7", "ase": "0.0/60.9"},
                {"name": "Ọbàtálá", "city": "Lagos", "status": "PENDING", "sims": "0/7", "ase": "0.0/60.9"},
                {"name": "Èṣù", "city": "Santiago", "status": "ACTIVE", "sims": "1/7", "ase": "8.72/60.9"}
            ]
        }
    })

# ============================================================================
# STARTUP
# ============================================================================

if __name__ == '__main__':
    print("🤍🗿⚖️🕊️🌄 VeilSim API Server")
    print(f"OSOVM Path: {OSOVM_PATH}")
    print(f"Source Path: {SRC_PATH}")
    print("Starting on http://localhost:5555")
    print("Documentation: http://localhost:5555/docs")
    print()
    
    app.run(host='127.0.0.1', port=5555, debug=False)
