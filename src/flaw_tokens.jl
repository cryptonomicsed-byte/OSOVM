# flaw_tokens.jl -- the 1440 Genesis Flaw Tokens
#
# Mythic root: Ọbàtálá, drunk on palm wine while molding the first humans,
# made them imperfect -- some too short, some without proper form. The flaw
# was never hidden or corrected; it became each person's mark, the thing
# that made them distinctly *theirs*. These tokens work the same way: each
# is a permanently, deliberately misspelled variant of "Àṣẹ" (the diacritics
# most keyboards can't type cleanly), one per Inheritance Wallet (1-1440).
# They are never corrected to the true spelling and never transferable --
# owning wallet N's specific flaw token *is* the proof you're entitled to
# that wallet's inheritance. This is a distinct mechanic from the single
# op_genesis_flaw (0x2b) ASHE->Àṣẹ mint at block 0, which mints the real
# currency; these are soulbound identity marks, not spendable Àṣẹ.
module FlawTokens

export generate_flaw_token, mint_all_flaw_tokens, verify_flaw_token,
       TRUE_SPELLING

"The one correct spelling -- no flaw token may ever equal this."
const TRUE_SPELLING = "Àṣẹ"

# Deterministic corruption pools per letter of "Àṣẹ", each deliberately
# excluding the correct diacritic for that position so no combination can
# ever reconstruct TRUE_SPELLING. Sizes 8x6x6x5 = 1440 exactly -- one
# unique, reproducible flaw per wallet, no randomness involved.
const POOL_A = ["A", "a", "Á", "Â", "Ä", "Ā", "Ã", "Å"]      # corruptions of À  (8)
const POOL_S = ["s", "S", "š", "ş", "ș", "ṡ"]                # corruptions of ṣ  (6)
const POOL_E = ["e", "E", "è", "é", "ê", "ë"]                # corruptions of ẹ  (6)
const POOL_MARK = ["", "'", "-", "_", "."]                   # trailing flaw mark (5)

const RADIX = (length(POOL_A), length(POOL_S), length(POOL_E), length(POOL_MARK))
@assert prod(RADIX) == 1440 "flaw token pool sizes must multiply to exactly 1440"

"""
    generate_flaw_token(wallet_id::Int) -> String

Pure, deterministic: the same wallet_id always produces the same flaw
token, and every wallet_id in 1:1440 produces a distinct one. No two
wallets can ever collide, and no output can ever equal TRUE_SPELLING.
"""
function generate_flaw_token(wallet_id::Int)::String
    if wallet_id < 1 || wallet_id > 1440
        throw(ArgumentError("wallet_id must be in 1:1440, got $wallet_id"))
    end
    idx = wallet_id - 1  # 0-indexed mixed-radix decomposition
    i_mark = idx % RADIX[4]; idx = div(idx, RADIX[4])
    i_e    = idx % RADIX[3]; idx = div(idx, RADIX[3])
    i_s    = idx % RADIX[2]; idx = div(idx, RADIX[2])
    i_a    = idx % RADIX[1]
    return POOL_A[i_a + 1] * POOL_S[i_s + 1] * POOL_E[i_e + 1] * POOL_MARK[i_mark + 1]
end

"""
    mint_all_flaw_tokens() -> Vector{String}

All 1440 tokens in wallet order (index i => wallet i). Used once at
genesis to seed each InheritanceWallet.flaw_token; never regenerated.
"""
function mint_all_flaw_tokens()::Vector{String}
    return [generate_flaw_token(i) for i in 1:1440]
end

"""
    verify_flaw_token(wallet_id, presented_token) -> Bool

The entitlement check: does the presented token match the one true flaw
token minted for this wallet at genesis? This -- not possession of any
Àṣẹ balance -- is what proves standing to claim a given wallet's
inheritance. Tokens are soulbound: there is deliberately no transfer
function anywhere in this module.
"""
function verify_flaw_token(wallet_id::Int, presented_token::String)::Bool
    if wallet_id < 1 || wallet_id > 1440
        return false
    end
    return presented_token == generate_flaw_token(wallet_id)
end

end # module
