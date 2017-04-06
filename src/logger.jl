module logger

export Logger, post

using Base.Dates

using ..Journal
using ..utils
using ..store

immutable Logger
    name::Symbol
    level::LogLevel
    stores::Vector{Store}
    children::Vector{Logger}
    function Logger{H <: Store}(
        name::Symbol;
        level::LogLevel=Journal.UNSET,
        stores::Vector{H}=Store[],
        children::Vector{Logger}=Logger[]
    )
        if isempty(stores) && isempty(children)
            error("Logger must have at least one store or at least one child logger")
        end
        for child in children
            if child.level < level
                warn("Child logger will be shadowed: $(child.name)")
            end
        end
        new(name, level, stores, children)
    end
end
function Logger(name::Symbol, data::Dict{Symbol, Any};
    stores::Dict{Symbol, Store}=Dict{Symbol, Store}(),
    loggers::Dict{Symbol, Logger}=Dict{Symbol, Logger}()
)
    if haskey(data, :level)
        data[:level] = convert(LogLevel, data[:level])
    end
    if haskey(data, :stores)
        data[:stores] = [isa(x, Union{Symbol, String}) ? stores[Symbol(x)] : Store(x) for x in data[:stores]]
    end
    if haskey(data, :children)
        data[:children] = [isa(x, Union{Symbol, String}) ? loggers[Symbol(x)] : Logger(x) for x in data[:children]]
    end
    Logger(name; data...)
end

function Base.print(io::IO, x::Logger)
    println(io, "$(x.name): $(x.level)")
    print(io, "children: ", join((child.name for child in x.children), ", "))
end
Base.show(io::IO, x::Logger) = print(io, x)

"""Post a message to a logger"""
function post(logger::Logger, level::LogLevel, topic::AbstractString, message::Any;
    timestamp::DateTime=now(UTC), kwargs...
)
    if level < logger.level
        # no logging necessary
        return
    end
    for store in logger.stores
        try
            write(store, timestamp, level, logger.name, topic, message; kwargs...)
        catch e
            warn("Unable to write log message: ", showerror(e))
        end
    end
    # pass message to children for processing
    for child in logger.children
        post(child, level, topic, message; timestamp=timestamp, kwargs...)
    end
    nothing
end
function post(logger::Logger, level::LogLevel, topic::AbstractString, first::Any, second::Any, rest::Any...; kwargs...)
    # collapse strings to a single message
    post(logger, level, topic, join([first; second; rest...], ""); kwargs...)
end

end
