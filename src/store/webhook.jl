module webhook

export WebhookStore, Authenticator

using Base.Dates

using JSON
using HttpCommon
using Requests
using URIParser

using ...Journal
using ...utils
using ..store

abstract Authenticator

"""Factory initialiser for custom Authenticators"""
function Authenticator(data::Dict{Symbol, Any})
    T = reduce(getfield, Main, map(Symbol, split(pop!(data, :type), '.')))::Type{Authenticator}
    T(data)
end

"""Webhook log store"""
immutable WebhookStore <: Store
    uri::URI
    key_map::Dict{Symbol, Symbol}
    data::Dict{Symbol, Any}
    headers::Dict{String, Any}
    query::Dict{Symbol, Any}
    authenticator::Nullable{Authenticator}
    max_backoff::TimePeriod
    max_attempts::Int
    gzip::Bool
    function WebhookStore(uri::URI,
        key_map::Dict{Symbol, Symbol}=Dict{Symbol, Symbol}();
        data::Dict{Symbol, Any}=Dict{Symbol, Any}(),
        headers::Dict{String, Any}=Dict{String, Any}(),
        query::Dict{Symbol, Any}=Dict{Symbol, Any}(),
        authenticator::Union{Authenticator, Void}=nothing,
        max_backoff::TimePeriod=Second(64), max_attempts::Int=10,
        gzip::Bool=true
    )
        new(uri, key_map, data, headers, query, authenticator, max_backoff, max_attempts, gzip)
    end
end
function WebhookStore(data::Dict{Symbol, Any})
    uri = URI(pop!(data, :uri))
    key_map = convert(Dict{Symbol, Symbol}, pop!(data, :key_map))
    if haskey(data, :headers)
        data[:headers] = convert(Dict{String, Any}, headers)
    end
    if haskey(data, :authenticator)
        data[:authenticator] = Authenticator(data[:authenticator])
    end
    WebhookStore(uri, key_map; data...)
end

function Base.print(io::IO, x::WebhookStore)
    print(io, x.uri)
end

function check(response::Response)
    status = statuscode(response)
    if (div(status, 100) == 5) || (status == 429)
        reason = HttpCommon.STATUS_CODES[status]
        Base.warn("Attempt failed: $reason ($status) ", get(response.request).uri)
        false
    else
        true
    end
end

function Base.write(store::WebhookStore,
    timestamp::DateTime, hostname::AbstractString, level::LogLevel, name::Symbol, topic::AbstractString, message::Any;
    async::Bool=true, kwargs...
)
    if async
        @async write(store, timestamp, hostname, level, name, topic, message; async=false, kwargs...)
        return
    end

    palette = Dict(
        :__timestamp__ => timestamp,
        :__hostname__ => hostname,
        :__level__ => string(level),
        :__name__ => string(name),
        :__topic__ => topic,
        :__message__ => message
    )
    data = merge(store.data, Dict(k => get(palette, v, nothing) for (k, v) in store.key_map), Dict(kwargs))

    # update headers/query parameters for authentication
    function task()
        try
            Requests.post(store.uri; json=data, headers=copy(store.headers), query=store.query, gzip_data=store.gzip)
        catch e
            if !(isa(e, Base.UVError) && in(e.code, [Base.UV_ECONNREFUSED, Base.UV_ETIMEDOUT]))
                throw(e)
            end
        end
    end

    if !isnull(store.authenticator)
        get(store.authenticator)(store.headers, store.query)
    end
    backoff(task, check, store.max_attempts, store.max_backoff)
end

end
