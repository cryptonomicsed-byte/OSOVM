# oso_compiler.jl — Ọ̀ṢỌ́ Compiler (OSO → IR)
# Parses OSO source and emits IR for VM execution
# Grammar: Attribute-based DSL with Òrìṣà semantics

module OsoCompiler

using JSON

include("opcodes.jl")
using .Opcodes

export compile_oso, Instruction, IR

# IR Instruction structure
struct Instruction
    opcode::UInt8
    args::Dict{Symbol, Any}
end

# IR is a vector of instructions
const IR = Vector{Instruction}

# Simple tokenizer for OSO syntax
struct Token
    type::Symbol  # :ATSYM, :IDENT, :LPAREN, :RPAREN, :LBRACE, :RBRACE, :EQ, :COMMA, :SEMI, :STRING, :NUMBER, :HASH
    value::String
    line::Int
    col::Int
end

# Lexer
function tokenize(source::String)::Vector{Token}
    tokens = Token[]
    lines = split(source, '\n')
    
    for (line_num, line) in enumerate(lines)
        col = 1
        i = 1
        while i <= length(line)
            c = line[i]
            
            # Skip whitespace
            if isspace(c)
                i += 1
                col += 1
                continue
            end
            
            # Skip comments
            if i < length(line) && line[i:i+1] == "//"
                break  # Skip rest of line
            end
            
            # @ symbol
            if c == '@'
                push!(tokens, Token(:ATSYM, "@", line_num, col))
                i += 1
                col += 1
            # Parentheses
            elseif c == '('
                push!(tokens, Token(:LPAREN, "(", line_num, col))
                i += 1
                col += 1
            elseif c == ')'
                push!(tokens, Token(:RPAREN, ")", line_num, col))
                i += 1
                col += 1
            # Braces
            elseif c == '{'
                push!(tokens, Token(:LBRACE, "{", line_num, col))
                i += 1
                col += 1
            elseif c == '}'
                push!(tokens, Token(:RBRACE, "}", line_num, col))
                i += 1
                col += 1
            # Semicolon
            elseif c == ';'
                push!(tokens, Token(:SEMI, ";", line_num, col))
                i += 1
                col += 1
            # Comma
            elseif c == ','
                push!(tokens, Token(:COMMA, ",", line_num, col))
                i += 1
                col += 1
            # Equals
            elseif c == '='
                push!(tokens, Token(:EQ, "=", line_num, col))
                i += 1
                col += 1
            # String literal
            elseif c == '"'
                start = i + 1
                i += 1
                while i <= length(line) && line[i] != '"'
                    i += 1
                end
                value = line[start:i-1]
                push!(tokens, Token(:STRING, value, line_num, col))
                i += 1
                col += i - start + 2
            # Hex hash (0x...)
            elseif i < length(line) && line[i:i+1] == "0x"
                start = i
                i += 2
                while i <= length(line) && (isdigit(line[i]) || line[i] in ['a', 'b', 'c', 'd', 'e', 'f', 'A', 'B', 'C', 'D', 'E', 'F'])
                    i += 1
                end
                value = line[start:i-1]
                push!(tokens, Token(:HASH, value, line_num, col))
                col += i - start
            # Number
            elseif isdigit(c) || (c == '-' && i < length(line) && isdigit(line[i+1]))
                start = i
                while i <= length(line) && (isdigit(line[i]) || line[i] == '.')
                    i += 1
                end
                value = line[start:i-1]
                push!(tokens, Token(:NUMBER, value, line_num, col))
                col += i - start
            # Identifier
            elseif isletter(c) || c == '_'
                start = i
                while i <= length(line) && (isletter(line[i]) || isdigit(line[i]) || line[i] == '_')
                    i += 1
                end
                value = line[start:i-1]
                push!(tokens, Token(:IDENT, value, line_num, col))
                col += i - start
            else
                i += 1
                col += 1
            end
        end
    end
    
    return tokens
end

# Parser
mutable struct Parser
    tokens::Vector{Token}
    pos::Int
end

function peek(p::Parser)::Union{Token, Nothing}
    p.pos <= length(p.tokens) ? p.tokens[p.pos] : nothing
end

function advance!(p::Parser)::Union{Token, Nothing}
    token = peek(p)
    p.pos += 1
    return token
end

function expect!(p::Parser, type::Symbol)::Token
    token = advance!(p)
    if token === nothing || token.type != type
        error("Expected $type, got $(token !== nothing ? token.type : "EOF")")
    end
    return token
end

# Parse attribute: @name(key=value, ...) or @name { ... }
function parse_attribute(p::Parser)::Instruction
    expect!(p, :ATSYM)
    name_token = expect!(p, :IDENT)
    attr_name = Symbol(uppercase(replace(name_token.value, r"([a-z])([A-Z])" => s"\1_\2")))
    
    # Get opcode
    opcode = Opcodes.get_opcode(attr_name)
    if opcode == 0x00 && attr_name != :HALT
        @warn "Unknown attribute: $attr_name, using NOOP"
        opcode = 0x01
    end
    
    args = Dict{Symbol, Any}()
    
    # Check for parameters or block
    next_token = peek(p)
    if next_token !== nothing && next_token.type == :LPAREN
        advance!(p)  # consume (
        
        # Parse key=value pairs
        while peek(p) !== nothing && peek(p).type != :RPAREN
            key_token = expect!(p, :IDENT)
            expect!(p, :EQ)
            value_token = advance!(p)
            
            key = Symbol(key_token.value)
            if value_token.type == :STRING
                args[key] = value_token.value
            elseif value_token.type == :NUMBER
                args[key] = contains(value_token.value, '.') ? parse(Float64, value_token.value) : parse(Int, value_token.value)
            elseif value_token.type == :HASH
                args[key] = value_token.value
            elseif value_token.type == :IDENT
                args[key] = value_token.value
            end
            
            # Optional comma
            if peek(p) !== nothing && peek(p).type == :COMMA
                advance!(p)
            end
        end
        
        expect!(p, :RPAREN)
    end
    
    # Check for block
    if peek(p) !== nothing && peek(p).type == :LBRACE
        advance!(p)  # consume {
        
        # Parse nested attributes
        nested = []
        while peek(p) !== nothing && peek(p).type != :RBRACE
            if peek(p).type == :ATSYM
                nested_instr = parse_attribute(p)
                push!(nested, nested_instr)
            end
            
            # Optional semicolon
            if peek(p) !== nothing && peek(p).type == :SEMI
                advance!(p)
            end
        end
        
        expect!(p, :RBRACE)
        
        if !isempty(nested)
            args[:nested] = nested
        end
    end
    
    return Instruction(opcode, args)
end

# Parse full program
function parse_program(p::Parser)::IR
    instructions = Instruction[]
    
    while peek(p) !== nothing
        if peek(p).type == :ATSYM
            instr = parse_attribute(p)
            push!(instructions, instr)
        else
            advance!(p)  # Skip unknown tokens
        end
        
        # Optional semicolon
        if peek(p) !== nothing && peek(p).type == :SEMI
            advance!(p)
        end
    end
    
    return instructions
end

"""
Compile OSO source code to IR
"""
function compile_oso(source::String)::IR
    # Tokenize
    tokens = tokenize(source)
    
    # Parse
    parser = Parser(tokens, 1)
    ir = parse_program(parser)
    
    # Validate
    validate_ir(ir)
    
    return ir
end

"""
Validate IR (ensure at least one core attribute)
"""
function validate_ir(ir::IR)::Nothing
    core_count = count(instr -> Opcodes.is_core(Opcodes.get_attribute(instr.opcode)), ir)
    
    if core_count < 1
        @warn "No core attributes found in program (recommended at least 1)"
    end
    
    nothing
end

"""
Serialize IR to JSON
"""
function serialize_ir(ir::IR)::String
    json_ir = [Dict("opcode" => instr.opcode, "args" => instr.args) for instr in ir]
    return JSON.json(json_ir, 2)
end

"""
Deserialize IR from JSON
"""
function deserialize_ir(json_str::String)::IR
    json_ir = JSON.parse(json_str)
    return [Instruction(UInt8(item["opcode"]), Dict(Symbol(k) => v for (k, v) in item["args"])) for item in json_ir]
end

end # module
