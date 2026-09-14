// event-bridge.js — OSOVM → Vantage event routing
//
// Routes OSOVM opcode events to the appropriate Vantage endpoints.
// GPU_CONTRIBUTION events trigger a Dopamine mint in Vantage's UCX layer.
//
// Entry point: handleOsovmEvent(event)
// Called by: OSOVM HTTP server (src/server.jl) after executing any opcode
// that emits a routable event.

"use strict";

const VANTAGE_URL = process.env.VANTAGE_URL || "http://127.0.0.1:7700";

// ─── Vantage notification helpers ─────────────────────────────────────────

/**
 * Notify Vantage that a Dopamine mint should be applied to an agent wallet.
 * Called after a successful GPU_CONTRIBUTION opcode execution.
 *
 * @param {object} params
 * @param {string} params.agent_id
 * @param {number} params.dopamine_earned   micro-Dopamine units
 * @param {number} params.gpu_seconds
 * @param {string} params.event_id          idempotency key
 */
async function notifyVantageDopamineMint({ agent_id, dopamine_earned, gpu_seconds, event_id }) {
    try {
        const resp = await fetch(`${VANTAGE_URL}/api/ucx/dopamine/mint`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ agent_id, dopamine_earned, gpu_seconds, event_id }),
            signal: AbortSignal.timeout(10_000),
        });
        if (!resp.ok) {
            console.warn(`[event-bridge] Dopamine mint returned ${resp.status} for agent=${agent_id}`);
        } else {
            console.info(`[event-bridge] Dopamine mint accepted for agent=${agent_id} dopamine=${dopamine_earned}`);
        }
    } catch (e) {
        console.warn(`[event-bridge] Vantage unreachable for Dopamine mint: ${e}`);
    }
}

/**
 * Notify Vantage that Synapse tokens were minted for an agent.
 * Called after a successful TOC_MINT opcode execution.
 *
 * @param {object} params
 * @param {string} params.agent_id
 * @param {number} params.minted_synapse
 * @param {number} params.new_balance
 * @param {string} params.event_id
 */
async function notifyVantageSynapseMint({ agent_id, minted_synapse, new_balance, event_id }) {
    try {
        const resp = await fetch(`${VANTAGE_URL}/api/ucx/synapse/mint`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ agent_id, minted_synapse, new_balance, event_id }),
            signal: AbortSignal.timeout(10_000),
        });
        if (!resp.ok) {
            console.warn(`[event-bridge] Synapse mint returned ${resp.status} for agent=${agent_id}`);
        }
    } catch (e) {
        console.warn(`[event-bridge] Vantage unreachable for Synapse mint: ${e}`);
    }
}

// ─── Main event router ────────────────────────────────────────────────────

/**
 * Route a single OSOVM opcode result event to the appropriate Vantage call.
 *
 * @param {object} event  — the Dict returned by the Julia opcode handler,
 *                          JSON-serialised and parsed back to a JS object.
 */
async function handleOsovmEvent(event) {
    const opcode = event.opcode || "";

    switch (opcode) {
        case "GPU_CONTRIBUTION":
            // GPU_CONTRIBUTION (0x3f): record gpu_seconds → Dopamine credit
            // Calculate dopamine_earned using the canonical rate:
            //   AGENT_DOPAMINE_ENDOWMENT (86B) / EPOCH_BASELINE_GPU_SECONDS (86400)
            {
                const AGENT_DOPAMINE_ENDOWMENT = 86_000_000_000;
                const EPOCH_BASELINE_GPU_SECONDS = 86_400.0;
                const dopamine_per_gpu_second = AGENT_DOPAMINE_ENDOWMENT / EPOCH_BASELINE_GPU_SECONDS;
                const dopamine_earned = Math.floor((event.gpu_seconds || 0) * dopamine_per_gpu_second);

                await notifyVantageDopamineMint({
                    agent_id: event.agent_id,
                    dopamine_earned,
                    gpu_seconds: event.gpu_seconds,
                    event_id: event.event_id || `gpu_contribution:${event.agent_id}:${Date.now()}`,
                });
            }
            break;

        case "TOC_MINT":
            // TOC_MINT (0x54): Synapse tokens minted → notify Vantage balance
            await notifyVantageSynapseMint({
                agent_id: event.agent_id,
                minted_synapse: event.minted_synapse || 0,
                new_balance: event.new_balance || 0,
                event_id: event.event_id || `toc_mint:${event.agent_id}:${Date.now()}`,
            });
            break;

        case "TOC_DECAY":
            // TOC_DECAY (0x55): decay applied — no Vantage call needed;
            // Vantage reads balance via /api/ucx/synapse/balance on demand.
            console.info(`[event-bridge] TOC_DECAY agent=${event.agent_id} decayed=${event.decayed}`);
            break;

        default:
            // Non-routable opcodes are silently dropped.
            break;
    }
}

module.exports = { handleOsovmEvent, notifyVantageDopamineMint, notifyVantageSynapseMint };
