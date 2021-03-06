__precompile__(true)

"""
Journal: Remote Logging Framework
"""

module Journal

export
    LogLevel,
    getlogger, getstore,
    register

using Base.Dates

using DataStructures
using YAML

function register end

"""Logging level"""
@enum LogLevel UNSET=-2 OFF=-1 ON=0 DEBUG INFO WARN ERROR

level_map = Dict(string(x) => x for x in instances(LogLevel))
Base.convert(::Type{LogLevel}, x::AbstractString) = haskey(level_map, x) ? level_map[x] : Base.error("Unknown logging level")

include("utils.jl")
include("store/store.jl")
include("logger.jl")

importall .utils
importall .store
importall .logger

"""Namespaces encapsulate site configuration for a loggers and stores"""
struct Namespace
    stores::Dict{Symbol, Store}
    loggers::Dict{Symbol, Logger}
    default::Logger
end
function Namespace()
    store = IOStore()
    logger = Logger(:_; level=INFO, stores=[store])
    stores = Dict{Symbol, Store}(:_ => store)
    loggers = Dict{Symbol, Logger}(:_ => logger)
    Namespace(stores, loggers, logger)
end
function Namespace{T <: Any}(data::Dict{Symbol, Any}; tags::Associative{Symbol, T}=Dict{Symbol, Any}())
    if !haskey(data, :stores)
        Base.error("Journal configuration is missing 'stores' key")
    end

    if !haskey(data, :loggers)
        Base.error("Journal configuration is missing 'loggers' key")
    end

    if isempty(data[:stores]) || isempty(data[:loggers])
        Base.error("Must have at least one store and at least one logger")
    end

    stores = Dict{Symbol, Store}(name => Store(x) for (name, x) in data[:stores])
    loggers = Dict{Symbol, Logger}()

    # resolve dependencies
    graph = deque(Tuple{Symbol, Vector{Symbol}, Dict{Symbol, Any}})
    for (name, x) in data[:loggers]
        push!(graph, (Symbol(name), map(Symbol, get(x, :children, String[])), x))
    end
    unresolved = Set{Symbol}()
    final = nothing
    while !isempty(graph)
        name, children, x = shift!(graph)
        if all(haskey(loggers, child) for child in children)
            logger = Logger(name, x; stores=stores, loggers=loggers)
            addtags!(logger, tags)
            loggers[name] = logger
            if in(name, unresolved)
                pop!(unresolved, name)
            end
            final = name
        else
            push!(unresolved, name)
            push!(graph, (name, children, x))
            if length(unresolved) == length(graph)
                # oops - been all the way around
                break
            end
        end
    end
    if !isempty(graph)
        found = collect(keys(loggers))
        missing = [(name, setdiff(children, found)) for (name, children) in graph]
        missing = join((" - $name: $(join(x, ", "))" for (name, x) in missing), "\n")
        Base.error("Loggers with unresolved children:\n", missing)
    end
    if haskey(data, :default)
        default = Symbol(data[:default])
        if !haskey(loggers, default)
            Base.error("Default logger not found: $default")
        end
        default = loggers[default]
    else
        # choose the "last" (undefined!) apical logger
        default = loggers[final]
    end
    Namespace(stores, loggers, default)
end

"""Namespaces"""
const _namespaces = Dict{Vector{Symbol}, Namespace}()

"""Gets a logger by name (optionally within a namespace)"""
function getlogger(name::Symbol, namespace::Vector{Symbol}=Symbol[])
    if !haskey(_namespaces, namespace)
        Base.error("Unknown namespace: [", join(namespace, ", "), "]")
    elseif !haskey(_namespaces[namespace].loggers, name)
        Base.error("Unknown logger name: [", join([namespace; name], ", "), "]")
    end
    _namespaces[namespace].loggers[name]
end
getlogger(name::String, namespace::Vector{Symbol}=Symbol[]) = getlogger(Symbol(name), namespace)
getlogger(namespace::Vector{Symbol}=Symbol[]) = haskey(_namespaces, namespace) ? _namespaces[namespace].default : Base.error("Unknown namespace: [", join(namespace, ", "), "]")
function Journal.getlogger(f::Function, args...; tags...)
    logger = copy(getlogger(args...))
    addtags!(logger, Dict(tags))
    f(logger)
end

"""Gets a store by name (optionally within a namespace)"""
function getstore(name::Symbol, namespace::Vector{Symbol}=Symbol[])
    if !haskey(_namespaces, namespace)
        Base.error("Unknown namespace: [", join(namespace, ", "), "]")
    elseif !haskey(_namespaces[namespace].stores, name)
        Base.error("Unknown store name: [", join([namespace; name], ", "), "]")
    end
    _namespaces[namespace].stores[name]
end
getstore(name::String, namespace::Vector{Symbol}=Symbol[]) = getstore(Symbol(name), namespace)

"""Configures a namespace"""
function config{T <: Any}(data::Dict{Symbol, Any};
    namespace::Union{Vector{Symbol}, Void}=nothing,
    tags::Associative{Symbol, T}=Dict{Symbol, Any}()
)
    if (namespace === nothing)
        namespace = pop!(data, :namespace, Symbol[])
        if !isa(namespace, AbstractVector)
            namespace = [namespace]
        end
        namespace = map(Symbol, namespace)
    elseif haskey(data, :namespace)
        pop!(data, :namespace)  # discard original namespace
    end
    _namespaces[namespace] = Namespace(data; tags=tags)
    nothing
end
function config{T <: Any}(filename::AbstractString;
    namespace::Union{Vector{Symbol}, Void}=nothing,
    tags::Associative{Symbol, T}=Dict{Symbol, Any}()
)
    directory = dirname(filename)
    cd(!isempty(directory) ? directory : ".") do
        data = dicttypeconvert(Dict{Symbol, Any}, YAML.load_file(basename(filename)))
        config(data; namespace=namespace, tags=tags)
    end
end

# create post alias for each log level
for level in instances(LogLevel)
    if level <= Journal.ON
        continue
    end
    f = Symbol(lowercase(string(level)))
    @eval function $f(logger::Logger, message...;
        topic::AbstractString=location(), value::Any=nothing,
        timestamp::DateTime=now(UTC), tags...
    )
        post(logger, $level, topic, value, message...; timestamp=timestamp, tags...)
    end
    @eval function $f(message...; logger::Logger=getlogger(),
        topic::AbstractString=location(), value::Any=nothing,
        timestamp::DateTime=now(UTC), tags...
    )
        post(logger, $level, topic, value, message...; timestamp=timestamp, tags...)
    end
end

function __init__()
    empty!(_namespaces)
    _namespaces[Symbol[]] = Namespace()  # ensure there is at least a default logger
end

end
