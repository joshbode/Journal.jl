module datastore

export DatastoreStore

using Base: Dates, Order

using JSON
using GoogleCloud
using GoogleCloud.api._datastore.types

using ...Journal
using ..store

"""Google Datastore log store"""
immutable DatastoreStore <: Store
    session::GoogleSession
    project::String
    path::Vector{Dict{Symbol, String}}
    max_backoff::TimePeriod
    max_attempts::Int
    function DatastoreStore(
        credentials::GoogleCredentials,
        scopes::Vector{String}=["datastore"],
        path::Vector{Dict{Symbol, String}}=[Dict(:kind => "log")],
        max_backoff::TimePeriod=Second(64), max_attempts::Int=10
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
        session = GoogleSession(credentials, scopes)
        project = session.credentials.project_id
        new(session, project, path, max_backoff, max_attempts)
    end
end
function DatastoreStore(data::Dict{Symbol, Any})
    credentials = GoogleCredentials(pop!(data, :credentials))
    DatastoreStore(credentials; data...)
end

function Base.print(io::IO, x::DatastoreStore)
    print(io, x.session)
end

function Base.write(store::DatastoreStore,
    timestamp::DateTime, hostname::AbstractString, level::LogLevel, name::Symbol, topic::AbstractString,
    value::Any, message::Any; async::Bool=true, tags...
)
    if async
        @async write(store, timestamp, hostname, level, name, topic, value, message; async=false, tags...)
        return
    end

    key = Dict(:path => store.path)
    properties = Dict(
        :timestamp => Dict(timestampValue => Base.Dates.format(timestamp, ISODateTimeFormat) * "Z"),
        :hostname => Dict(stringValue => hostname),
        :level => Dict(stringValue => string(level)),
        :name => Dict(stringValue => string(name)),
        :topic => Dict(stringValue => topic),
        :value => wrap(value),
        :message => wrap(message)
    )
    merge!(properties, Dict(k => wrap(v) for (k, v) in tags))
    result = GoogleCloud.datastore(:Project, :commit, store.project;
        session=store.session, max_attempts=store.max_attempts, fields="indexUpdates",
        data=Dict(:mode => "NON_TRANSACTIONAL", :mutations => Dict(:insert => Dict(:key => key, :properties => properties)))
    )
    if haskey(result, :error)
        warn("Datastore error: ", result[:error][:message])
    end
end

date_filter(date::Date, operator::OperatorType) = date_filter(DateTime(date), operator)
function date_filter(date::DateTime, operator::OperatorType)
    Dict(:propertyFilter => Dict(
        :property => Dict(:name => "timestamp"), :op => operator,
        :value => Dict(timestampValue => Base.Dates.format(date, ISODateTimeFormat) * "Z")
    ))
end

function Base.read{T <: Any}(store::DatastoreStore;
    start::Union{TimeType, Void}=nothing,
    finish::Union{TimeType, Void}=nothing,
    filter::Associative{Symbol, T}=Dict{Symbol, Any}()
)
    if (start !== nothing) && (finish !== nothing) && (start > finish)
        error("Start cannot be after finish: $start, $finish")
    end

    kind = [Dict(:name => store.path[end][:kind])]
    filters = Dict[
        Dict(:propertyFilter => Dict(:property => Dict(:name => name), :op => EQUAL, :value => wrap(x)))
        for (name, x) in filter
    ]
    # add timestamp ranges
    if start !== nothing
        push!(filters, date_filter(start, GREATER_THAN_OR_EQUAL))
    end
    if finish !== nothing
        push!(filters, date_filter(finish, LESS_THAN_OR_EQUAL))
    end
    filter = !isempty(filters) ? Dict(:compositeFilter => Dict(:op => "AND", :filters => filters)) : nothing
    order = Dict(:property => Dict(:name => "timestamp"))
    result = GoogleCloud.datastore(:Project, :runQuery, store.project;
        session=store.session, max_attempts=store.max_attempts, fields="batch(entityResults(entity(properties)))",
        data=Dict(:query => Dict(:kind => kind, :filter => filter, :order => order))
    )
    if haskey(result, :error)
        error("Datastore error: ", result[:error][:message])
    end
    entries = Dict{Symbol, Any}[
        Dict(name => unwrap(x) for (name, x) in row[:entity][:properties])
        for row in get(result[:batch], :entityResults, [])
    ]
    for entry in entries
        entry[:name] = convert(Symbol, entry[:name])
        entry[:level] = convert(LogLevel, entry[:level])
    end
    entries
end

end
