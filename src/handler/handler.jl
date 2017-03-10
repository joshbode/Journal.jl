module handler

export
    Handler, register, process, IOHandler, WebhookHandler, DatastoreHandler

using ..Journal

abstract Handler

"""Factory for handlers"""
Handler(handler_type::Symbol, args...; kwargs...) = handlertype(handler_type)(args...; kwargs...)
Handler(handler_type::Symbol, data::Dict{Symbol, Any}) = handlertype(handler_type)(data)
Handler(data::Dict{Symbol, Any}) = Handler(Symbol(pop!(data, :type)), data)

"""Process a log message through a handler"""
process(handler::Handler,
    timestamp::DateTime, level::LogLevel, name::Symbol, message::Any;
    async::Bool=true
) = Base.error("Not Implemented: process(handler::$(typeof(handler)), ...)")

"""Register a new handler by name"""
function register{H <: Handler}(handler_type::Symbol, ::Type{H})
    handler_map[handler_type] = H
end

"""Get handler type"""
handlertype(handler_type::Symbol) = haskey(handler_map, handler_type) ? handler_map[handler_type] : Base.error("Unknown handler type: $handler_type")

"""Handler type map"""
const handler_map = Dict{Symbol, Type}()

"""Initialise the module: add handlers to handler map"""
function __init__()
    empty!(handler_map)
    register(:io, IOHandler)
    register(:webhook, WebhookHandler)
    register(:datastore, DatastoreHandler)
end

include("io.jl")
include("datastore.jl")
include("webhook.jl")

importall .io
importall .datastore
importall .webhook

end
