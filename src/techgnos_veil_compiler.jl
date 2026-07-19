"""
    TechGnosVeilCompiler - @veil directive compiler extensions
    
Extends TechGnos language with veil-specific syntax:
  @veil(id: N, parameters: {...})
  @veil(id: N) -> @veil(id: M)  [composition]
  @veil_if(condition) { @veil(...) }
  @veil_score(f1: value)
"""

module TechGnosVeilCompiler

export VeilDirective, VeilCompose, VeilScore, VeilIf, parse_veil_directive

include("opcodes_veil.jl")
using .OpcodeVeil

# ============================================================================
# AST NODE TYPES
# ============================================================================

"""Abstract base for veil AST nodes"""
abstract type VeilASTNode end

"""
    VeilDirective - Basic @veil(id: N) invocation
    
Fields:
  - veil_id::Int - Which veil to execute
  - parameters::Dict{String, Any} - Named parameters
  - ffi_language::String - Target implementation language
"""
struct VeilDirective <: VeilASTNode
    veil_id::Int
    parameters::Dict{String, Any}
    opcode::UInt16
    ffi_language::String
    tags::Vector{String}
end

"""
    VeilCompose - @veil(id: A) -> @veil(id: B) composition
    
Fields:
  - veil_sequence::Vector{Int} - Ordered veil IDs
  - data_flow::Dict - Parameter passing between veils
"""
struct VeilCompose <: VeilASTNode
    veil_sequence::Vector{Int}
    data_flow::Dict{Int, Dict{String, String}}  # veil_id => {param => source}
end

"""
    VeilScore - @veil_score(f1: value) F1 scoring for reward
    
Fields:
  - f1_score::Union{Symbol, Float64} - Score or variable reference
  - veil_id::Int - Which veil to score
  - reward_amount::Float64 - Àṣẹ to mint if F1 >= 0.9
"""
struct VeilScore <: VeilASTNode
    f1_score::Union{Symbol, Float64}
    veil_id::Int
    reward_amount::Float64
end

"""
    VeilIf - @veil_if(condition) { @veil(...) } conditional
    
Fields:
  - condition::Expr - Boolean expression
  - veil_directive::VeilDirective - Body to execute
"""
struct VeilIf <: VeilASTNode
    condition::Any  # Expression
    body::VeilDirective
    else_body::Union{VeilDirective, Nothing}
end

# ============================================================================
# VEIL TOKENIZER
# ============================================================================

"""Token types for veil syntax"""
@enum VeilTokenType begin
    TK_AT
    TK_VEIL
    TK_VEIL_IF
    TK_VEIL_SCORE
    TK_LPAREN
    TK_RPAREN
    TK_LBRACE
    TK_RBRACE
    TK_COLON
    TK_COMMA
    TK_ARROW
    TK_EQUALS
    TK_ID
    TK_NUMBER
    TK_STRING
    TK_SYMBOL
    TK_EOF
end

"""Veil token structure"""
struct VeilToken
    type::VeilTokenType
    value::Any
    line::Int
    column::Int
end

"""
    tokenize_veil(source::String) -> Vector{VeilToken}

Tokenize @veil directive syntax.
"""
function tokenize_veil(source::String)::Vector{VeilToken}
    tokens = VeilToken[]
    i = 1
    line = 1
    column = 1
    
    while i <= length(source)
        # Skip whitespace
        if source[i] in (' ', '\t', '\n', '\r')
            if source[i] == '\n'
                line += 1
                column = 1
            else
                column += 1
            end
            i += 1
            continue
        end
        
        # Comments
        if i + 1 <= length(source) && source[i:i+1] == "//"
            while i <= length(source) && source[i] != '\n'
                i += 1
            end
            continue
        end
        
        # Multi-character tokens
        if source[i] == '@'
            if startswith(source[i:end], "@veil_if")
                push!(tokens, VeilToken(TK_VEIL_IF, "@veil_if", line, column))
                i += 8
                column += 8
            elseif startswith(source[i:end], "@veil_score")
                push!(tokens, VeilToken(TK_VEIL_SCORE, "@veil_score", line, column))
                i += 11
                column += 11
            elseif startswith(source[i:end], "@veil")
                push!(tokens, VeilToken(TK_VEIL, "@veil", line, column))
                i += 5
                column += 5
            else
                push!(tokens, VeilToken(TK_AT, "@", line, column))
                i += 1
                column += 1
            end
            continue
        end
        
        if source[i] == '-' && i + 1 <= length(source) && source[i+1] == '>'
            push!(tokens, VeilToken(TK_ARROW, "->", line, column))
            i += 2
            column += 2
            continue
        end
        
        # Single-character tokens
        single_char_map = Dict(
            '(' => TK_LPAREN,
            ')' => TK_RPAREN,
            '{' => TK_LBRACE,
            '}' => TK_RBRACE,
            ':' => TK_COLON,
            ',' => TK_COMMA,
            '=' => TK_EQUALS
        )
        
        if haskey(single_char_map, source[i])
            push!(tokens, VeilToken(single_char_map[source[i]], string(source[i]), line, column))
            i += 1
            column += 1
            continue
        end
        
        # Numbers
        if isdigit(source[i])
            j = i
            while j <= length(source) && (isdigit(source[j]) || source[j] == '.')
                j += 1
            end
            num_str = source[i:j-1]
            value = if '.' in num_str
                parse(Float64, num_str)
            else
                parse(Int, num_str)
            end
            push!(tokens, VeilToken(TK_NUMBER, value, line, column))
            column += j - i
            i = j
            continue
        end
        
        # Strings
        if source[i] in ('"', '\'')
            quote_char = source[i]
            j = i + 1
            while j <= length(source) && source[j] != quote_char
                j += 1
            end
            str_value = source[i+1:j-1]
            push!(tokens, VeilToken(TK_STRING, str_value, line, column))
            column += j - i + 1
            i = j + 1
            continue
        end
        
        # Identifiers and symbols
        if isalpha(source[i]) || source[i] in ('_',)
            j = i
            while j <= length(source) && (isalnum(source[j]) || source[j] == '_')
                j += 1
            end
            id_str = source[i:j-1]
            push!(tokens, VeilToken(TK_ID, id_str, line, column))
            column += j - i
            i = j
            continue
        end
        
        # Skip unknown characters
        i += 1
        column += 1
    end
    
    push!(tokens, VeilToken(TK_EOF, nothing, line, column))
    return tokens
end

# ============================================================================
# VEIL PARSER
# ============================================================================

"""Parser state for veil directives"""
mutable struct VeilParser
    tokens::Vector{VeilToken}
    pos::Int
    current::VeilToken
end

"""Create a parser from tokens"""
function VeilParser(tokens::Vector{VeilToken})
    parser = VeilParser(tokens, 1, tokens[1])
    return parser
end

"""Advance to next token"""
function advance!(parser::VeilParser)
    if parser.pos < length(parser.tokens)
        parser.pos += 1
        parser.current = parser.tokens[parser.pos]
    end
end

"""Check if current token matches type"""
function match(parser::VeilParser, token_type::VeilTokenType)::Bool
    parser.current.type == token_type
end

"""Expect token type and advance"""
function expect!(parser::VeilParser, token_type::VeilTokenType)::VeilToken
    if !match(parser, token_type)
        error("Expected $(token_type), got $(parser.current.type)")
    end
    token = parser.current
    advance!(parser)
    return token
end

"""Parse a single veil directive"""
function parse_veil_directive(source::String)::Union{VeilDirective, VeilCompose, VeilScore, VeilIf, Nothing}
    tokens = tokenize_veil(source)
    parser = VeilParser(tokens)
    
    try
        if match(parser, TK_VEIL)
            return parse_veil_invocation!(parser)
        elseif match(parser, TK_VEIL_IF)
            return parse_veil_if!(parser)
        elseif match(parser, TK_VEIL_SCORE)
            return parse_veil_score!(parser)
        else
            return nothing
        end
    catch e
        error("Parse error: $e")
    end
end

"""Parse @veil(id: N, parameters: {...}) invocation"""
function parse_veil_invocation!(parser::VeilParser)::VeilDirective
    expect!(parser, TK_VEIL)
    expect!(parser, TK_LPAREN)
    
    veil_id = nothing
    parameters = Dict{String, Any}()
    
    # Parse id: value
    while !match(parser, TK_RPAREN)
        param_name = expect!(parser, TK_ID).value
        expect!(parser, TK_COLON)
        param_value = parse_veil_value!(parser)
        
        if param_name == "id"
            veil_id = param_value
        else
            parameters[param_name] = param_value
        end
        
        if match(parser, TK_COMMA)
            advance!(parser)
        end
    end
    
    expect!(parser, TK_RPAREN)
    
    # Get opcode and FFI info
    opcode = OpcodeVeil.get_veil_opcode(veil_id)
    veil_def = Veils777.get_veil(veil_id)
    
    return VeilDirective(
        veil_id,
        parameters,
        opcode,
        veil_def.ffi_language,
        veil_def.tags
    )
end

"""Parse @veil_if(condition) { ... }"""
function parse_veil_if!(parser::VeilParser)::VeilIf
    expect!(parser, TK_VEIL_IF)
    expect!(parser, TK_LPAREN)
    
    # Parse condition (simplified - just capture as symbol for now)
    condition = if match(parser, TK_ID)
        expect!(parser, TK_ID).value
    else
        error("Expected condition in @veil_if")
    end
    
    expect!(parser, TK_RPAREN)
    expect!(parser, TK_LBRACE)
    
    body = parse_veil_invocation!(parser)
    
    expect!(parser, TK_RBRACE)
    
    return VeilIf(condition, body, nothing)
end

"""Parse @veil_score(f1: value)"""
function parse_veil_score!(parser::VeilParser)::VeilScore
    expect!(parser, TK_VEIL_SCORE)
    expect!(parser, TK_LPAREN)
    
    f1_score = nothing
    veil_id = nothing
    reward = 5.0
    
    while !match(parser, TK_RPAREN)
        param = expect!(parser, TK_ID).value
        expect!(parser, TK_COLON)
        value = parse_veil_value!(parser)
        
        if param == "f1"
            f1_score = value
        elseif param == "veil_id"
            veil_id = value
        elseif param == "reward"
            reward = value
        end
        
        if match(parser, TK_COMMA)
            advance!(parser)
        end
    end
    
    expect!(parser, TK_RPAREN)
    
    return VeilScore(f1_score, veil_id, reward)
end

"""Parse a parameter value"""
function parse_veil_value!(parser::VeilParser)::Any
    if match(parser, TK_NUMBER)
        val = parser.current.value
        advance!(parser)
        return val
    elseif match(parser, TK_STRING)
        val = parser.current.value
        advance!(parser)
        return val
    elseif match(parser, TK_ID)
        val = parser.current.value
        advance!(parser)
        return val
    elseif match(parser, TK_LBRACE)
        # Parse dict
        advance!(parser)
        dict = Dict{String, Any}()
        while !match(parser, TK_RBRACE)
            key = expect!(parser, TK_ID).value
            expect!(parser, TK_COLON)
            value = parse_veil_value!(parser)
            dict[key] = value
            
            if match(parser, TK_COMMA)
                advance!(parser)
            end
        end
        expect!(parser, TK_RBRACE)
        return dict
    else
        error("Unexpected token: $(parser.current.type)")
    end
end

# ============================================================================
# CODE GENERATION
# ============================================================================

"""
    veil_to_ir(directive::VeilDirective) -> Dict

Convert veil directive to intermediate representation (IR).
"""
function veil_to_ir(directive::VeilDirective)::Dict
    return Dict(
        "type" => "veil_call",
        "veil_id" => directive.veil_id,
        "opcode" => string(directive.opcode; base=16),
        "ffi_language" => directive.ffi_language,
        "parameters" => directive.parameters,
        "tags" => directive.tags
    )
end

"""
    veil_compose_to_ir(compose::VeilCompose) -> Dict

Convert veil composition to IR (pipeline).
"""
function veil_compose_to_ir(compose::VeilCompose)::Dict
    return Dict(
        "type" => "veil_compose",
        "veil_sequence" => compose.veil_sequence,
        "opcodes" => [string(OpcodeVeil.get_veil_opcode(id); base=16) for id in compose.veil_sequence],
        "data_flow" => compose.data_flow
    )
end

"""
    veil_score_to_ir(score::VeilScore) -> Dict

Convert veil scoring to IR.
"""
function veil_score_to_ir(score::VeilScore)::Dict
    return Dict(
        "type" => "veil_score",
        "veil_id" => score.veil_id,
        "f1_score" => score.f1_score,
        "opcode" => string(OpcodeVeil.OPCODE_VEIL_SCORE; base=16),
        "reward" => score.reward_amount
    )
end

"""
    veil_if_to_ir(conditional::VeilIf) -> Dict

Convert veil conditional to IR.
"""
function veil_if_to_ir(conditional::VeilIf)::Dict
    return Dict(
        "type" => "veil_if",
        "condition" => conditional.condition,
        "body" => veil_to_ir(conditional.body),
        "else_body" => conditional.else_body !== nothing ? veil_to_ir(conditional.else_body) : nothing
    )
end

end # module TechGnosVeilCompiler
