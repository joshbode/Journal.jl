module transform

export Transform

using ...Journal

"""Transform type map"""
const transform_map = Dict{Symbol, Type}()

"""Get transform type"""
transformtype(transform_type::Symbol) = haskey(transform_map, transform_type) ? transform_map[transform_type] : error("Unknown transform type: $transform_type")

abstract Transform

Base.show(io::IO, x::Transform) = print(io, x)

"""Factory for Transforms"""
Transform(transform_type::Symbol, args...; kwargs...) = transformtype(transform_type)(args...; kwargs...)
Transform(data::Dict{Symbol, Any}) = Transform(Symbol(pop!(data, :type)), data)

"""Register a new transform by name"""
function Journal.register{S <: Transform}(::Type{S}, transform_type::Symbol)
    if haskey(transform_map, transform_type)
        warn("Transform type already exists. Overwriting: $transform_type")
    end
    transform_map[transform_type] = S
end


"""Identity transform"""
immutable Identity <: Transform end
Identity(data::Dict{Symbol, Any}) = Identity(; data...)
(t::Identity)(x::AbstractArray) = (x, 1:length(x))


"""Standard transform"""
immutable Standard <: Transform
    shift::Float64
    scale::Float64
    floor::Float64
    ceiling::Float64
    function Standard(;
        shift::AbstractFloat=0.0, scale::AbstractFloat=1.0,
        floor::AbstractFloat=-Inf, ceiling::AbstractFloat=Inf
    )
        if scale == 0.0
            error("Scale must be non-zero")
        elseif floor >= ceiling
            error("Floor must be less than the ceiling")
        end
        new(shift, scale, floor, ceiling)
    end
end
Standard(data::Dict{Symbol, Any}) = Standard(; data...)
(t::Standard)(x::AbstractVector) = (map!((v) -> min(max(v, t.floor), t.ceiling), Array(Float64, length(x)), (x .- t.shift) ./ t.scale), 1:length(x))


"""Offset difference transform"""
immutable Difference <: Transform
    offset::Int
    relative::Bool
    Difference(; offset::Integer=1, relative::Bool=true) = new(offset, relative)
end
Difference(data::Dict{Symbol, Any}) = Difference(; data...)
function (t::Difference)(x::AbstractArray)
    if t.offset == 0
        return x
    end
    n = length(x)
    i = t.offset > 0 ? ((1 + t.offset):n) : (1:(n + t.offset)) 
    result = x[i] .- x[i - t.offset]
    (t.relative ? result ./ x[i - t.offset] : result, i)
end


"""Rolling transform"""
immutable Rolling{F <: Function} <: Transform
    width::Int
    function Rolling(;
        width::Integer=1
    )
        if width <= 0
            error("Rolling transform width must be positive")
        end
        new(width)
    end
end
function Rolling(data::Dict{Symbol, Any})
    f = reduce(getfield, Main, map(Symbol, split(pop!(data, :f), '#')))::Function
    Rolling{Type{f}}(; data...)
end
function (t::Rolling{Type{mean}})(x::AbstractVector)
    n = length(x)
    k = min(t.width, n)
    result = Array(Float64, n - k + 1)
    state = mean(x[1:k])
    result[1] = state
    for i = (k + 1):n
        state += (x[i] - x[i - k]) / k
        result[i - k + 1] = state
    end
    (result, k:n)
end
function (t::Rolling{Type{sum}})(x::AbstractVector)
    n = length(x)
    k = min(t.width, n)
    result = Array(eltype(x), n - k + 1)
    state = sum(x[1:k])
    result[1] = state
    for i = (k + 1):n
        state += (x[i] - x[i - k])
        result[i - k + 1] = state
    end
    (result, k:n)
end
function (t::Rolling{Type{min}})(x::AbstractVector)
    n = length(x)
    k = min(t.width, n)
    result = Array(Float64, n - k + 1)
    state = Array(eltype(x), k)
    state[:] = x[1:k]
    value, index = findmin(state)
    result[1] = value
    for i = 2:(n + 1 - k)
        curr_value, curr_index = x[i + k - 1], (i - 2) % k + 1
        state[curr_index] = curr_value
        if curr_value <= value
            value, index = curr_value, curr_index
        elseif index == curr_index
            value, index = findmin(state)
        end
        result[i] = value
    end
    (result, k:n)
end
function (t::Rolling{Type{max}})(x::AbstractVector)
    n = length(x)
    k = min(t.width, n)
    result = Array(Float64, n - k + 1)
    state = Array(eltype(x), k)
    state[:] = x[1:k]
    value, index = findmax(state)
    result[1] = value
    for i = 2:(n + 1 - k)
        curr_value, curr_index = x[i + k - 1], (i - 2) % k + 1
        state[curr_index] = curr_value
        if curr_value >= value
            value, index = curr_value, curr_index
        elseif index == curr_index
            value, index = findmax(state)
        end
        result[i] = value
    end
    (result, k:n)
end


"""General function transform"""
immutable General <: Transform
    wrapper::Function
    function General(f::Function;
        args::AbstractVector{Any}=Any[],
        kwargs::Dict{Symbol, Any}=Dict{Symbol, Any}(),
        vectorise::Bool=false
    )
        wrapper = (x) -> f([collect(x); args]...; kwargs...)
        new(vectorise ? (x) -> map((a...) -> wrapper(a), x...) : wrapper)
    end
end
function General(data::Dict{Symbol, Any})
    f = replace(pop!(data, :f), r"(?<=\w)\.(?=\w)", "#")  # don't replace dot in operator names (e.g. .<=)
    f = reduce(getfield, Main, map(Symbol, split(f, '#')))::Function
    General(f; data...)
end
(t::General)(x::AbstractVector...) = (t.wrapper(x), 1:length(x))

"""Initialise the module: add transforms to transform map"""
function __init__()
    empty!(transform_map)
    register(Identity, :identity)
    register(Standard, :standard)
    register(Difference, :difference)
    register(Rolling, :rolling)
    register(General, :general)
end

end
