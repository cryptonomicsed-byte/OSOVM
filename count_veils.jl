include("src/veils_777.jl")
using .Veils777
all_v = Veils777.get_all_veils()
println("total veils in ALL_VEILS: ", length(all_v))
placeholder = count(v -> occursin("description", lowercase(v.equation)) || occursin(r"Veil \d+$", v.name), all_v)
println("placeholder-pattern veils (generic name/templated equation): ", placeholder)
println("real/authored veils: ", length(all_v) - placeholder)
println()
println("--- sample of 'real' (non-placeholder) veils ---")
for v in filter(v -> !(occursin("description", lowercase(v.equation)) || occursin(r"Veil \d+$", v.name)), all_v)
    println(v.id, ": ", v.name, " | ", v.equation)
end
