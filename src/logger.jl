module logger

export Logger, post, addtags!, cleartags!

using Base.Dates

using ..Journal
using ..utils
using ..store

immutable Logger
    name::Symbol
    level::LogLevel
    stores::Vector{Store}
    children::Vector{Logger}
    tags::Dict{Symbol, Any}
    function Logger{H <: Store}(
        name::Symbol;
        level::LogLevel=Journal.UNSET,
        stores::Vector{H}=Store[],
        children::Vector{Logger}=Logger[],
        tags::Dict{Symbol, Any}=Dict{Symbol, Any}()
    )
        if isempty(stores) && isempty(children)
            error("Logger must have at least one store or at least one child logger")
        end
        for child in children
            if child.level < level
                warn("Child logger will be shadowed: $(child.name)")
            end
        end
        new(name, level, stores, children, tags)
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

Base.copy(logger::Logger) = Logger(logger.name;
    level=logger.level,
    stores=copy(logger.stores),
    children=copy(logger.children),
    tags=copy(logger.tags)
)

"""Updates tags for logger"""
addtags!(logger::Logger, tags::Associative) = merge!(logger.tags, tags)
cleartags!(logger::Logger) = empty!(logger.tags)

"""Post a message to a logger"""
function post(logger::Logger, level::LogLevel, topic::AbstractString, value::Any, message::Any=nothing;
    timestamp::DateTime=now(UTC), hostname::AbstractString=gethostname(), tags...
)
    if level < logger.level
        # no logging necessary
        return
    end
    tags = merge(logger.tags, Dict(tags))
    for store in logger.stores
        try
            write(store, timestamp, hostname, level, logger.name, topic, value, message; tags...)
        catch e
            warn("Unable to write log message: ", show_error(e))
        end
    end
    # pass message to children for processing
    for child in logger.children
        post(child, level, topic, value, message; timestamp=timestamp, hostname=hostname, tags...)
    end
    nothing
end
function post(logger::Logger, level::LogLevel, topic::AbstractString, value::Any, exception::Exception; tags...)
    post(logger, level, topic, value, show_error(exception); tags...)
end
function post(logger::Logger, level::LogLevel, topic::AbstractString, value::Any, message::Any, rest::Any...; tags...)
    post(logger, level, topic, value, string(message) * join(rest, ""); tags...)
end

end
