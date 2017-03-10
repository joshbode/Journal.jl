__precompile__(true)

"""
Journal: Remote Logging Framework
"""

module Journal

export
    LogLevel, getlogger, gethandler, Logger,
    Handler, IOHandler, DatastoreHandler

using Base.Dates

using Compat
using DataStructures
using YAML

"""Logging level"""
@enum LogLevel UNSET=-2 OFF=-1 ON=0 DEBUG WARN INFO ERROR

level_map = Dict(string(x) => x for x in instances(LogLevel))
Base.convert(::Type{LogLevel}, x::AbstractString) = haskey(level_map, x) ? level_map[x] : Base.error("Unknown logging level")

include("utils.jl")
include("handler/handler.jl")
include("logger.jl")

using .handler
using .logger

"""Logger map"""
const _loggers = Dict{Vector{Symbol}, Dict{Symbol, Logger}}()

"""Handler map"""
const _handlers = Dict{Vector{Symbol}, Dict{Symbol, Handler}}()

"""Default logger"""
const _default = Dict{Vector{Symbol}, Logger}()

function __init__()
    empty!(_loggers)
    empty!(_default)
    empty!(_handlers)
end

"""Gets a logger by name (optionally within a namespace)"""
function getlogger(name::Symbol, namespace::Vector{Symbol}=Symbol[])
    if !haskey(_loggers, namespace)
        Base.error("Unknown namespace: [", join(namespace, ", "), "]")
    elseif !haskey(_loggers[namespace], name)
        Base.error("Unknown logger name: [", join([namespace; name], ", "), "]")
    end
    _loggers[namespace][name]
end
getlogger(namespace::Vector{Symbol}=Symbol[]) = haskey(_default, namespace) ? _default[namespace] : Base.error("No default logger: [", join(namespace, ", "), "]")

"""Gets a handler by name (optionally within a namespace)"""
function gethandler(name::Symbol, namespace::Vector{Symbol}=Symbol[])
    if !haskey(_handlers, namespace)
        Base.error("Unknown namespace: [", join(namespace, ", "), "]")
    elseif !haskey(_handlers[namespace], name)
        Base.error("Unknown handler name: [", join([namespace; name], ", "), "]")
    end
    _handlers[namespace][name]
end

"""Configure loggers and handlers"""
function config(data::Dict{Symbol, Any}; namespace::Vector{Symbol}=Symbol[])
    if isempty(namespace) && haskey(data, :namespace) && (data[:namespace] !== nothing)
        namespace = data[:namespace]
        if !isa(namespace, Vector)
            namespace = [namespace]
        end
        namespace = map(Symbol, namespace)
    end
    if !haskey(data, :handlers)
        Base.error("Journal configuration is missing 'handlers' key")
    end
    handlers = data[:handlers]

    if !haskey(data, :loggers)
        Base.error("Journal configuration is missing 'loggers' key")
    end
    loggers = data[:loggers]
    if isempty(handlers) || isempty(loggers)
        Base.error("Logger must have at least one handler or at least one child logger")
    end

    _handlers[namespace] = Dict{Symbol, Handler}(name => Handler(x) for (name, x) in data[:handlers])
    _loggers[namespace] = Dict{Symbol, Logger}()

    # resolve dependencies
    graph = deque(Tuple{Symbol, Vector{Symbol}})
    for (name, x) in loggers
        push!(graph, (name, map(Symbol, get(x, :children, String[]))))
    end
    unresolved = Set{Symbol}()
    while !isempty(graph)
        name, children = shift!(graph)
        if all(haskey(_loggers[namespace], x) for x in children)
            _loggers[namespace][name] = Logger(name, loggers[name]; namespace=namespace)
            if in(name, unresolved)
                pop!(unresolved, name)
            end
        else
            push!(unresolved, name)
            push!(graph, (name, children))
            if length(unresolved) == length(graph)
                # oops - been all the way around
                break
            end
        end
    end
    if !isempty(graph)
        found = collect(keys(_loggers[namespace]))
        missing = [(name, setdiff(children, found)) for (name, children) in graph]
        missing = join((" - $name: $(join(x, ", "))" for (name, x) in missing), "\n")
        Base.error("Loggers with unresolved children:\n", missing)
    end
    if haskey(data, :default)
        _default[namespace] = getlogger(data[:default], namespace)
    else
        _default[namespace] = Logger(Symbol(join(namespace, '.')); level=INFO, handlers=[IOHandler()])
    end
    nothing
end

"""Recursively converts dictionary key/value types"""
#deepconvert{K, V, T <: Associative{K, V}}(::Type{T}, x::Associative) = T(  # 0.6 can't come quickly enough
deepconvert{K, V}(T::Type{Dict{K, V}}, x::Associative) = T(
    convert(K, k) => isa(v, Associative) ? deepconvert(T, v) : convert(V, v)
    for (k, v) in x
)

config(filename::AbstractString) = config(deepconvert(Dict{Symbol, Any}, YAML.load_file(filename)))

# create post alias for each log level
for level in instances(LogLevel)
    if level <= Journal.ON
        continue
    end
    f = Symbol(lowercase(string(level)))
    @eval function $f(logger::Logger, message...; timestamp::DateTime=now(UTC), async::Bool=true, kwargs...)
        post(logger, $level, message...; timestamp=timestamp, async=async, kwargs...)
    end
end

end
