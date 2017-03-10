module webhook

export WebhookHandler, Authenticator

using Base.Dates

using JSON
using HttpCommon
using Requests
using URIParser

using ...Journal
using ...utils
using ..handler

abstract Authenticator

"""Factory initialiser for custom Authenticators"""
function Authenticator(data::Dict{Symbol, Any})
    T = reduce(getfield, Main, map(Symbol, split(pop!(data, :type), '.')))
    @assert T <: Authenticator
    T(data)
end

"""Webhook log handler"""
immutable WebhookHandler <: Handler
    uri::URI
    template::Function
    headers::Dict{String, Any}
    query::Dict{Symbol, Any}
    authenticator::Nullable{Authenticator}
    max_backoff::TimePeriod
    max_attempts::Int64
    gzip::Bool
    function WebhookHandler(uri::URI,
        key_map::Dict{Symbol, Symbol}=Dict{Symbol, Symbol}();
        message_key::Symbol=:message,
        data::Dict{Symbol, Any}=Dict{Symbol, Any}(),
        headers::Dict{String, Any}=Dict{String, Any}(),
        query::Dict{Symbol, Any}=Dict{Symbol, Any}(),
        authenticator::Union{Authenticator, Void}=nothing,
        max_backoff::TimePeriod=Second(64), max_attempts::Int64=10,
        gzip::Bool=true
    )
        template = @eval function $(gensym(:template))(timestamp, level, name, message)
            # populate POST data with info from message or fall back to template
            leader = Dict(
                :__timestamp__ => timestamp,
                :__level__ => string(level),
                :__name__ => name,
                :__raw__ => message,
            )
            if isa(message, Associative)
                leader[:__message__] = pop!(message, $message_key, nothing)
                message = merge!(leader, message)
            else
                leader[:__message__] = message
                message = leader
            end
            merge($data, Dict(k => get(message, v, nothing) for (k, v) in $key_map))
        end
        new(uri, template, headers, query, authenticator, max_backoff, max_attempts, gzip)
    end
end
function WebhookHandler(data::Dict{Symbol, Any})
    uri = URI(pop!(data, :uri))
    key_map = convert(Dict{Symbol, Symbol}, pop!(data, :key_map))
    if haskey(data, :message_key)
        data[:message_key] = Symbol(data[:message_key])
    end
    if haskey(data, :headers)
        data[:headers] = convert(Dict{String, Any}, headers)
    end
    if haskey(data, :authenticator)
        data[:authenticator] = Authenticator(data[:authenticator])
    end
    WebhookHandler(uri, key_map; data...)
end

function Base.print(io::IO, x::WebhookHandler)
    print(io, x.uri)
end
Base.show(io::IO, x::WebhookHandler) = print(io, x)

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

function handler.process(handler::WebhookHandler,
    timestamp::DateTime, level::LogLevel, name::Symbol, message::Any;
    async::Bool=true
)
    if async
        @async process(handler, timestamp, level, name, message; async=false)
        return
    end

    data = handler.template(timestamp, level, name, message)
    # update headers/query parameters for authentication
    if !isnull(handler.authenticator)
        get(handler.authenticator)(handler.headers, handler.query)
    end
    task = () -> Requests.post(handler.uri; json=data, headers=copy(handler.headers), query=handler.query, gzip_data=handler.gzip)
    backoff(task, check, handler.max_attempts, handler.max_backoff)
end

end
