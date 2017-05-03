module check

export Check

using Compat

using ...Journal

"""Check type map"""
const check_map = Dict{Symbol, Type}()

"""Get check type"""
checktype(check_type::Symbol) = haskey(check_map, check_type) ? check_map[check_type] : error("Unknown check type: $check_type")

@compat abstract type Check end

Base.show(io::IO, x::Check) = print(io, x)

"""Factory for Checks"""
Check(check_type::Symbol, args...; kwargs...) = checktype(check_type)(args...; kwargs...)
Check(data::Dict{Symbol, Any}) = Check(Symbol(pop!(data, :type)), data)

"""Register a new check by name"""
function Journal.register{S <: Check}(::Type{S}, check_type::Symbol)
    if haskey(check_map, check_type)
        warn("Check type already exists. Overwriting: $check_type")
    end
    check_map[check_type] = S
end

immutable Tautology <: Check end
(c::Tautology)(x::AbstractVector) = trues(x)

function Base.print(io::IO, x::Tautology)
    print(io, "name: ", x.name)
end


immutable Range{T <: Real} <: Check
    min::T
    max::T
    function Range(; min::T=typemin(T), max::T=typemax(T))
        new(min, max)
    end
end
function Range(data::Dict{Symbol, Any})
    if haskey(data, :min) && haskey(data, :max)
        min, max = promote(data[:min], data[:max])
        Range{typejoin(typeof(min), typeof(max))}(; min=min, max=max)
    elseif haskey(data, :min)
        min = data[:min]
        Range{typeof(min)}(; min=min)
    elseif haskey(data, :max)
        max = data[:max]
        Range{typeof(max)}(; max=max)
    else
        Range{Float64}()
    end
end
(c::Range)(x::AbstractVector) = c.min .<= x .<= c.max


immutable Value{T <: Real} <: Check
    value::T
    tolerance::T
    Value(value::T; tolerance::T=sqrt(eps)) = new(value, tolerance)
end
function Value(data::Dict{Symbol, Any})
    value = pop!(data, :value)
    Value{typeof(value)}(value; data...)
end
(c::Value)(x::AbstractVector) = map((a) -> isapprox(a, c.value; rtol=c.tolerance), x)


"""Initialise the module: add checks to check map"""
function __init__()
    empty!(check_map)
    register(Tautology, :tautology)
    register(Range, :range)
    register(Value, :value)
end

end
