module io

export IOHandler

using Base.Dates

using ...Journal
using ..handler

"""Basic IO (files, streams) log handler"""
immutable IOHandler <: Handler
    io::IO
    template::Function
    timestamp_format::DateFormat
    function IOHandler(;
        io::IO=STDERR,
        format::AbstractString="\$timestamp: \$level: \$name: ",
        timestamp_format::Union{DateFormat, AbstractString}=ISODateTimeFormat
    )
        format = parse("\"$format\"")
        template = @eval $(gensym(:template))(timestamp, level, name) = $format
        new(io, template, timestamp_format)
    end
end
function IOHandler(data::Dict{Symbol, Any})
    if haskey(data, :file)
        file = pop!(data, :file)
        if length(file) == 1
            # default to write
            append!(file, "w")
        end
        data[:io] = open(file...)
    end
    IOHandler(; data...)
end

function Base.print(io::IO, x::IOHandler)
    print(io, "io: ", x.io)
end
Base.show(io::IO, x::IOHandler) = print(io, x)

function handler.process(handler::IOHandler,
    timestamp::DateTime, level::LogLevel, name::Symbol, message::Any;
    async::Bool=true
)
    leader = handler.template(
        Base.Dates.format(timestamp, handler.timestamp_format), level, name
    )
    write(handler.io, leader, message, '\n')
    flush(handler.io)
end

end
