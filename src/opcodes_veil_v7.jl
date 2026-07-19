module OpcodesVeilV7

export OPCODE_VEIL, OPCODE_VEIL_COMPOSE, OPCODE_VEIL_SCORE
export OPCODE_START_SIM, OPCODE_WITNESS_SIM
export VEIL_OPCODE_MAP, opcode_to_veil, veil_to_opcode

# Core veil opcodes (0x70, 0x71)
const OPCODE_START_SIM = 0x70           # startSim(veilId: uint16)
const OPCODE_WITNESS_SIM = 0x71         # witnessSim(citizen, veilId, f1)

# Legacy opcodes (preserved for compatibility)
const OPCODE_VEIL = 0x12                # Main veil dispatcher
const OPCODE_VEIL_COMPOSE = 0x13        # Veil composition
const OPCODE_VEIL_SCORE = 0x14          # F1 scoring

# Mapping: Veil ID → Opcode (reserved for future use)
const VEIL_OPCODE_MAP = Dict(
    1 => 0x01,      # PID Controller
    7 => 0x07,      # LQR Controller
    23 => 0x17,     # Deep Q-Network
    77 => 0x4d,     # Kalman Filter
    111 => 0x6f,    # Particle Swarm
    177 => 0xb1,    # Transformer (GPT)
    369 => 0x171,   # SLAM (Mapping)
    444 => 0x1bc,   # NSGA-II
    555 => 0x22b,   # Diffusion Model
    666 => 0x29a,   # Model Predictive Control
    777 => 0x309,   # VQE (Quantum)
)

function opcode_to_veil(opcode::Int)::Int
    for (veil_id, opc) in VEIL_OPCODE_MAP
        if opc == opcode
            return veil_id
        end
    end
    return -1  # Not found
end

function veil_to_opcode(veil_id::Int)::Int
    return get(VEIL_OPCODE_MAP, veil_id, -1)
end

end # module OpcodesVeilV7
