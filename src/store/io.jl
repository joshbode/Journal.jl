module io

export IOStore

using Base.Dates

using JSON
using TimeZones

using ...Journal
using ...utils
using ..store

"""Basic IO (files, streams) log store"""
struct IOStore <: Store
    io::IO
    template::Function
    parser::Function
    timestamp_format::DateFormat
    timezone::TimeZone
    function IOStore(;
        io::IO=STDERR,
        format::AbstractString="\$timestamp: \$level: \$name: \$topic: \$message",
        timestamp_format::Union{DateFormat, AbstractString}=TimeZones.ISOZonedDateTimeFormat,
        timezone::TimeZone=localzone()
    )
        template = make_template(format)
        parser = make_parser(format)
        new(io, template, parser, timestamp_format, timezone)
    end
end
function IOStore(data::Dict{Symbol, Any})
    if haskey(data, :file)
        file = pop!(data, :file)
        if !isa(file, AbstractVector)
            file = [file]
        end
        if length(file) == 1
            # default to read/write
            push!(file, "w+")
        end
        data[:io] = open(file...)
    end
    if haskey(data, :timezone)
        data[:timezone] = TimeZone(data[:timezone])
    end
    IOStore(; data...)
end

function Base.print(io::IO, x::IOStore)
    print(io, "io: ", x.io)
end

function Base.write(store::IOStore,
    timestamp::DateTime, hostname::AbstractString, level::LogLevel, name::Symbol, topic::AbstractString,
    value::Any, message::Any; async::Bool=false, tags...
)
    # don't write message-less entries
    if message === nothing
        return
    end
    timestamp = astimezone(ZonedDateTime(timestamp, TimeZone("UTC")), store.timezone)
    data = store.template(;
        timestamp=Base.Dates.format(timestamp, store.timestamp_format), hostname=hostname,
        level=level, name=name, topic=topic,
        value=json(value), message=message
    )
    println(store.io, data)
    flush(store.io)
end

"""Check if string is likely to be JSON"""
isjson(x::AbstractString) = (
    (first(x) in ['"', '[', '{']) ||
    (x in ["true", "false", "null"]) ||
    ismatch(r"^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?$", x)
)

"""Converts record fields to original types"""
function convert_entry(x, timestamp_format, timezone)
    x[:timestamp] = DateTime(astimezone(ZonedDateTime(x[:timestamp], timestamp_format), timezone))
    x[:level] = haskey(x, :level) ? convert(LogLevel, x[:level]) : ON
    x[:name] = haskey(x, :name) ? Symbol(x[:name]) : Symbol()
    if !haskey(x, :topic)
        x[:topic] = nothing
    end
    if haskey(x, :value) && !isempty(x[:value])
        if isjson(x[:value])
            try
                x[:value] = JSON.parse(x[:value])
            end
        end
    else
        x[:value] = nothing
    end
    if haskey(x, :message) && !isempty(x[:message])
        if isjson(x[:message])
            try
                x[:message] = JSON.parse(x[:message])
            end
        end
    else
        x[:message] = nothing
    end
    x
end

function Base.read{T <: Any}(store::IOStore;
    start::Union{TimeType, Void}=nothing,
    finish::Union{TimeType, Void}=nothing,
    filter::Associative{Symbol, T}=Dict{Symbol, Any}()
)
    if !isreadable(store.io)
        error("IO is not readable")
    end
    if (start !== nothing) && (finish !== nothing) && (start > finish)
        error("Start cannot be after finish: $start, $finish")
    end
    invalid = setdiff(keys(filter), [:level, :name, :topic])
    if !isempty(invalid)
        warn("Unapplied filters: ", join(invalid, ", "))
        filter = Base.filter((k, v) -> in(k, [:level, :name, :topic]), filter)
    end
    if !isempty(filter)
        filter = Dict(k => isa(v, AbstractVector) ? v : [v] for (k, v) in filter)
    end

    seek(store.io, 0)
    entries = map(store.parser, readlines(store.io))
    entries = Base.filter!((x) -> haskey(x, :timestamp), entries)  # remove any non-conforming records
    timestamp_format, timezone = store.timestamp_format, TimeZone("UTC")
    entries = map!((x) -> convert_entry(x, timestamp_format, timezone), entries)

    # apply any filters
    if (start !== nothing) || (finish !== nothing) || !isempty(filter)
        if start === nothing
            start = typemin(DateTime)
        end
        if finish === nothing
            finish = typemax(DateTime)
        end
        check(x) = (start <= x[:timestamp] <= finish) && all(in(x[k], v) for (k, v) in filter)
        entries = Base.filter!(check, entries)
    end
    entries
end

end
