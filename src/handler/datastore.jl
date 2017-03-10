module datastore

export DatastoreHandler

using GoogleCloud

using ...Journal
using ..handler

"""Google Datastore log handler"""
immutable DatastoreHandler <: Handler
    function DatastoreHandler(;
    )
        new()
    end
end
function DatastoreHandler(data::Dict{Symbol, Any})
    DatastoreHandler(; data...)
end

function Base.print(io::IO, x::DatastoreHandler)

end
Base.show(io::IO, x::DatastoreHandler) = print(io, x)

function handler.process(handler::DatastoreHandler,
    timestamp::DateTime, level::LogLevel, name::Symbol, message::Any;
    async::Bool=true
)

end

end
