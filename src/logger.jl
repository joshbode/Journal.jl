module logger

export Logger, post

using Base.Dates

using ..Journal
using ..utils
using ..handler

immutable Logger
    name::Symbol
    level::LogLevel
    handlers::Vector{Handler}
    children::Vector{Logger}
    function Logger{H <: Handler}(
        name::Symbol;
        level::LogLevel=Journal.UNSET,
        handlers::Vector{H}=Handler[],
        children::Vector{Logger}=Logger[]
    )
        if isempty(handlers) && isempty(children)
            error("Logger must have at least one handler or at least one child logger")
        end
        for child in children
            if child.level < level
                warn("Child logger will be shadowed: $(child.name)")
            end
        end
        new(name, level, handlers, children)
    end
end
function Logger(name::Symbol, data::Dict{Symbol, Any}; namespace::Vector{Symbol}=Symbol[])
    if haskey(data, :level)
        data[:level] = convert(LogLevel, data[:level])
    end
    if haskey(data, :handlers)
        data[:handlers] = [isa(x, Union{Symbol, String}) ? gethandler(x, namespace) : Handler(x) for x in data[:handlers]]
    end
    if haskey(data, :children)
        data[:children] = [isa(x, Union{Symbol, String}) ? getlogger(x, namespace) : Logger(x) for x in data[:children]]
    end
    Logger(name; data...)
end

function Base.print(io::IO, x::Logger)
    println(io, "$(x.name): $(x.level)")
    print(io, "children: ", join((child.name for child in x.children), ", "))
end
Base.show(io::IO, x::Logger) = print(io, x)

"""Post a message to a logger"""
function post(logger::Logger, level::LogLevel, message::Any;
    timestamp::DateTime=now(UTC), async::Bool=true, kwargs...
)
    if level < logger.level
        # no logging necessary
        return
    end
    for handler in logger.handlers
        try
            process(handler, timestamp, level, logger.name, message; async=async)
        catch e
            warn("Unable to process log message: ", showerror(e))
        end
    end
    # pass message to children for processing
    for child in logger.children
        post(child, level, message; timestamp=timestamp, async=async)
    end
    nothing
end
function post(logger::Logger, level::LogLevel, first::Any, second::Any, rest::Any...; kwargs...)
    # collapse strings to a single message
    post(logger, level, join([first; second; rest...], ""); kwargs...)
end

end
