module datastore

export DatastoreHandler

using Base.Dates

using JSON
using GoogleCloud
import GoogleCloud.api._datastore: DatastoreValueType

using ...Journal
using ..handler

"""Google Datastore log handler"""
immutable DatastoreHandler <: Handler
    session::GoogleSession
    project::String
    template::Function
    path::Vector{Dict{Symbol, String}}
    max_backoff::TimePeriod
    max_attempts::Int64
    function DatastoreHandler(
        credentials::GoogleCredentials,
        key_map::Dict{Symbol, Tuple{Symbol, DatastoreValueType}}=Dict{Symbol, Tuple{Symbol, DatastoreValueType}}(),
        message_key::Symbol=:message;
        scopes::Vector{String}=["datastore"],
        path::Vector{Dict{Symbol, String}}=[Dict(:kind => "log")],
        max_backoff::TimePeriod=Second(64), max_attempts::Int64=10
    )
        if !all(haskey(x, :kind) for x in path)
            message = join(("  - $(json(x))" for x in path), "\n")
            error("All path elements must have a kind:\n", message)
        end
        if !all(haskey(x, :name) for x in path[1:(end - 1)])
            message = join(("  - $(json(x))" for x in path), "\n")
            error("All path elements (but last) must have a name:\n", message)
        end
        if haskey(last(path), :name)
            error("Last path element must have no name: ", json(path))
        end
        template = @eval function $(gensym(:template))(timestamp, level, name, message)
            # populate POST data with info from message or fall back to template
            leader = Dict(
                :__timestamp__ => Base.Dates.format(timestamp, ISODateTimeFormat) * "Z",
                :__level__ => string(level),
                :__name__ => string(name),
                :__raw__ =>  base64encode(json(message))
            )
            if isa(message, Associative)
                if haskey(message, $message_key)
                    leader[:__message__] = message[$message_key]
                end
                message = merge!(leader, message)
            else
                leader[:__message__] = string(message)
                message = leader
            end
            Dict(
                k => Dict(t => message[v])
                for (k, (v, t)) in $key_map
                if haskey(message, v)
            )
        end
        session = GoogleSession(credentials, scopes)
        project = session.credentials.project_id
        new(session, project, template, path, max_backoff, max_attempts)
    end
end
function DatastoreHandler(data::Dict{Symbol, Any})
    credentials = GoogleCredentials(pop!(data, :credentials))
    key_map = Dict(
        k => (Symbol(v), convert(DatastoreValueType, t))
        for (k, (v, t)) in pop!(data, :key_map)
    )
    DatastoreHandler(credentials, key_map; data...)
end

function Base.print(io::IO, x::DatastoreHandler)
    print(io, x.credentials)
end
Base.show(io::IO, x::DatastoreHandler) = print(io, x)

function handler.process(handler::DatastoreHandler,
    timestamp::DateTime, level::LogLevel, name::Symbol, message::Any;
    async::Bool=true
)
    if async
        @async process(handler, timestamp, level, name, message; async=false)
        return
    end

    result = GoogleCloud.datastore(:Project, :commit, handler.project;
        debug=true,
        session=handler.session, max_attempts=handler.max_attempts, fields="indexUpdates",
        data=Dict(
            :mode => "NON_TRANSACTIONAL",
            :mutations => Dict(
                :insert => Dict(
                    :key => Dict(:path => handler.path),
                    :properties => handler.template(timestamp, level, name, message)
                )
            )
        )
    )
    if haskey(result, :error)
        warn("Datastore error: ", result[:error][:message])
    end
end

end
