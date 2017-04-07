module metric

export Transform, Check, Metric, Suite

using Base: Dates, Order

using ..Journal
using ..logger
using ..store
using ..utils

include("transform.jl")
include("check.jl")

importall .transform
importall .check

function Base.parse(::Type{Period}, x::Dict{Symbol, Any})
    if !haskey(x, :unit)
        error("Missing unit")
    end
    T = getfield(Base.Dates, Symbol(ucfirst(x[:unit])))
    if !(T <: Period)
        error("Invalid unit type: ", x[:unit])
    end
    T(get(x, :count, 1))
end

# map ordering to sample type
order_map = Dict{String, Ordering}("first" => Forward, "last" => Reverse)

"""Represents the input for a metric"""
immutable Input
    period::Nullable{Period}
    frequency::Nullable{Period}
    sample::Union{ForwardOrdering, ReverseOrdering{ForwardOrdering}}
    store::Store
    topic::String
    attributes::Dict{Symbol, Any}
    function Input(store::Store, topic::AbstractString;
        period::Union{Period, Void}=nothing,
        frequency::Union{Period, Void}=nothing,
        sample::Union{ForwardOrdering, ReverseOrdering{ForwardOrdering}}=Reverse,
        attributes::Dict{Symbol, Any}=Dict{Symbol, Any}()
    )
        new(period, frequency, sample, store, topic, attributes)
    end
end
function Input(data::Dict{Symbol, Any};
    stores::Dict{Symbol, Store}=Dict{Symbol, Store}()
)
    store = pop!(data, :store)
    store = isa(store, Union{Symbol, String}) ? stores[Symbol(store)] : Store(store)
    topic = pop!(data, :topic)
    if haskey(data, :period) && (data[:period] !== nothing)
        data[:period] = parse(Period, data[:period])
    end
    if haskey(data, :frequency) && (data[:frequency] !== nothing)
        data[:frequency] = parse(Period, data[:frequency])
    end
    if haskey(data, :sample)
        data[:sample] = haskey(order_map, data[:sample]) ? order_map[data[:sample]] : error("Unknown sample type: ", data[:sample])
    end
    Input(store, topic; data...)
end

"""Retrieves (and filters) data for an input"""
function retrieve(x::Input;
    attributes::Dict{Symbol, Any}=Dict{Symbol, Any}(),
    cutoff::Union{TimeType, Void}=nothing
)
    filter = merge(attributes, x.attributes, Dict(:topic => x.topic))
    kwargs = Dict{Symbol, Union{TimeType, Void}}()
    if !isnull(x.period)
        if cutoff === nothing
            cutoff = today()
        end
        start = kwargs[:start] = cutoff - get(x.period)
    else
        start = nothing
    end
    finish = kwargs[:finish] = cutoff
    data = read(x.store; filter=filter, kwargs...)
    if isempty(data)
        warn("No data found")
        return Dict{Symbol, Any}[]
    end
    # infer end points
    dates = [r[:timestamp] for r in data]
    if start === nothing
        start = minimum(dates)
    end
    if finish === nothing
        finish = maximum(dates)
    end
    # if necessary, coarsen out data frequency
    if !isempty(data) && !isnull(x.frequency)
        grid = start:get(x.frequency):finish
        mask = coarsen(dates, grid; sample=x.sample)
        data = data[mask]
    end
    data
end

"""Represents the output for a metric"""
immutable Output
    period::Nullable{Period}
    frequency::Nullable{Period}
    sample::Union{ForwardOrdering, ReverseOrdering{ForwardOrdering}}
    logger::Logger
    level::LogLevel
    topic::String
    message::Function
    attributes::Dict{Symbol, Any}
    function Output(logger::Logger, topic::String, message::AbstractString;
        period::Union{Period, Void}=nothing,
        frequency::Union{Period, Void}=nothing,
        sample::Union{ForwardOrdering, ReverseOrdering{ForwardOrdering}}=Reverse,
        level::LogLevel=ERROR,
        attributes::Dict{Symbol, Any}=Dict{Symbol, Any}()
    )
        message = make_template(message)
        new(period, frequency, sample, logger, level, topic, message, attributes)
    end
end
function Output(data::Dict{Symbol, Any};
    loggers::Dict{Symbol, Logger}=Dict{Symbol, Logger}()
)
    logger = pop!(data, :logger)
    logger = isa(logger, Union{Symbol, String}) ? loggers[Symbol(logger)] : Logger(logger)
    topic = pop!(data, :topic)
    message = chomp(pop!(data, :message))
    if haskey(data, :period) && (data[:period] !== nothing)
        data[:period] = parse(Period, data[:period])
    end
    if haskey(data, :frequency) && (data[:frequency] !== nothing)
        data[:frequency] = parse(Period, data[:frequency])
    end
    if haskey(data, :sample)
        data[:sample] = haskey(order_map, data[:sample]) ? order_map[data[:sample]] : error("Unknown sample type: ", data[:sample])
    end
    data[:level] = convert(LogLevel, data[:level])
    Output(logger, topic, message; data...)
end

"""Produces the result of the metric and logs it"""
function report{T <: Associative}(x::Output,
    data::AbstractVector{T}, series::AbstractVector, result::AbstractVector{Bool},
    leader::Function, name::AbstractString;
    attributes::Dict{Symbol, Any}=Dict{Symbol, Any}(),
    cutoff::Union{TimeType, Void}=nothing
)
    finish = cutoff !== nothing ? cutoff : today()
    start = !isnull(x.period) ? finish - get(x.period) : typemin(Date)
    data = Base.filter!((x) -> (start <= x[:timestamp] <= finish), data)
    # if necessary, coarsen out data frequency
    if !isempty(data) && !isnull(x.frequency)
        grid = start:get(x.frequency):finish
        dates = [r[:timestamp] for r in data]
        mask = coarsen(dates, grid; sample=x.sample)
        data, series, result = data[mask], series[mask], result[mask]
    end
    if !isempty(result) && all(result)
        return
    end
    # evaluate the message
    attributes = merge(attributes, x.attributes)
    leader = leader(; topic=x.topic, name=name, attributes...)
    message = isempty(result) ? "$header: No data present" : x.message(;
        leader=leader, topic=x.topic,
        data=data, series=series, result=result,
        attributes...
    )
    post(x.logger, x.level, x.topic, message; attributes...)
end

"""A metric, comprising an input, transformation, check and output"""
immutable Metric
    name::String
    attributes::Dict{Symbol, Any}
    active::Bool
    invert::Bool
    input::Input
    transform::Transform
    check::Check
    output::Output
    function Metric(
        name::String,
        input::Input, transform::Transform,
        check::Check, output::Output;
        attributes::Dict{Symbol, Any}=Dict{Symbol, Any}(),
        active::Bool=true, invert::Bool=false
    )
        new(name, attributes, active, invert, input, transform, check, output)
    end
end
function Metric(data::Dict{Symbol, Any};
    stores::Dict{Symbol, Store}=Dict{Symbol, Store}(),
    loggers::Dict{Symbol, Logger}=Dict{Symbol, Logger}()
)
    name = pop!(data, :name)
    input = Input(pop!(data, :input); stores=stores)
    transform = Transform(pop!(data, :transform))
    check = Check(pop!(data, :check))
    output = Output(pop!(data, :output); loggers=loggers)
    Metric(name, input, transform, check, output; data...)
end

function Base.print(io::IO, x::Metric)
    print(io, "name: ", x.name)
end
Base.show(io::IO, x::Metric) = print(io, x)

"""Evaluates the metric"""
function evaluate(x::Metric, leader::Function;
    attributes::Dict{Symbol, Any}=Dict{Symbol, Any},
    cutoff::Union{TimeType, Void}=nothing
)
    if !x.active
        return
    end
    attributes = merge(attributes, x.attributes)
    data = retrieve(x.input; attributes=attributes, cutoff=cutoff)
    series, range = x.transform([r[:message] for r in data])
    result = x.check(series)
    if x.invert
        result = !result
    end
    if !isempty(result) && all(result)
        return
    end
    report(
        x.output, data[range], series, result, leader, x.name;
        attributes=attributes, cutoff=cutoff
    )
end

"""A collection of metrics"""
immutable Suite
    attributes::Vector{Symbol}
    leader::Function
    metrics::Dict{String, Metric}
    function Suite(metrics::Vector{Metric};
        leader::AbstractString="",
        attributes::AbstractVector{Symbol}=Symbol[]
    )
        metrics = Dict(x.name => x for x in metrics)
        leader = make_template(leader)
        new(attributes, leader, metrics)
    end
end
function Suite(data::Dict{Symbol, Any};
    stores::Dict{Symbol, Store}=Dict{Symbol, Store}(),
    loggers::Dict{Symbol, Logger}=Dict{Symbol, Logger}()
)
    defaults = pop!(data, :defaults, Dict{Symbol, Any}())
    data[:attributes] = map(Symbol, data[:attributes])
    metrics = [Metric(deepmerge(defaults, x); stores=stores, loggers=loggers) for x in pop!(data, :metrics)]
    Suite(metrics; data...)
end

function Base.print(io::IO, x::Suite)
    println(io, "attributes: ", x.attributes)
    print(io, "metrics: ", join(keys(x.metrics), "\n"))
end
Base.show(io::IO, x::Suite) = print(io, x)

"""Runs the suite of metrics, optionally on a subset of metrics by name"""
function Base.run{S <: AbstractString}(x::Suite;
    attributes::Dict{Symbol, Any}=Dict{Symbol, Any}(),
    cutoff::TimeType=now(),
    metrics::AbstractVector{S}=String[]
)
    missing = setdiff(x.attributes, keys(attributes))
    if !isempty(missing)
        error("Missing attributes: ", join(missing, ", "))
    end
    metrics = isempty(metrics) ? x.metrics : filter((k, v) -> in(k, metrics), x.metrics)
    for (name, metric) in metrics
        evaluate(metric, x.leader; attributes=attributes, cutoff=cutoff)
    end
end

end
