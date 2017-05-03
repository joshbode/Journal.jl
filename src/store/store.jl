module store

export
    Store, IOStore, WebhookStore, DatastoreStore

using Compat

using ..Journal

"""Store type map"""
const store_map = Dict{Symbol, Type}()

"""Get store type"""
storetype(store_type::Symbol) = haskey(store_map, store_type) ? store_map[store_type] : error("Unknown store type: $store_type")

@compat abstract type Store end

Base.show(io::IO, x::Store) = print(io, x)

"""Factory for Stores"""
Store(store_type::Symbol, args...; kwargs...) = storetype(store_type)(args...; kwargs...)
Store(data::Dict{Symbol, Any}; kwargs...) = Store(Symbol(pop!(data, :type)), data; kwargs...)

"""Register a new store by name"""
function Journal.register{S <: Store}(::Type{S}, store_type::Symbol)
    if haskey(store_map, store_type)
        warn("Store type already exists. Overwriting: $store_type")
    end
    store_map[store_type] = S
end

include("io.jl")
include("datastore.jl")
include("webhook.jl")

importall .io
importall .datastore
importall .webhook

"""Initialise the module: add stores to store map"""
function __init__()
    empty!(store_map)
    register(IOStore, :io)
    register(WebhookStore, :webhook)
    register(DatastoreStore, :datastore)
end

end
