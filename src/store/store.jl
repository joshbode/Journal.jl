module store

export
    Store, IOStore, WebhookStore, DatastoreStore

using ..Journal

"""Store type map"""
const store_map = Dict{Symbol, Type}()

"""Get store type"""
storetype(store_type::Symbol) = haskey(store_map, store_type) ? store_map[store_type] : error("Unknown store type: $store_type")

abstract Store

"""Factory for Stores"""
Store(store_type::Symbol, args...; kwargs...) = storetype(store_type)(args...; kwargs...)
Store(store_type::Symbol, data::Dict{Symbol, Any}) = storetype(store_type)(data)
Store(data::Dict{Symbol, Any}) = Store(Symbol(pop!(data, :type)), data)

"""Register a new store by name"""
function Journal.register{S <: Store}(::Type{S}, store_type::Symbol)
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
