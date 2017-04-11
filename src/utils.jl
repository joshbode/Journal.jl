module utils

export
    lineage, location, frame,
    backoff,
    deepconvert, deepmerge,
    matchdict, make_template, make_parser,
    coarsen

using Compat

using Base: Dates, Order

function check(x)
    info = ccall(:jl_lookup_code_address, Any, (Ptr{Void}, Cint), x - 1, false)
    info[1][1] == Symbol("")
end

"""Captures error messages and optionally the backtrace."""
function Base.showerror(e::Exception; backtrace=true)
    if backtrace
        trace = catch_backtrace()[3:end]
        i = findfirst(check, trace)
        if i > 1
            trace = trace[1:(i - 1)]
        end
        sprint((io) -> showerror(io, e, trace))
    else
        sprint((io) -> showerror(io, e))
    end
end

PKG_DIR = Pkg.dir()

function frame(n)
    trace = backtrace()
    ccall(:jl_lookup_code_address, Any, (Ptr{Void}, Cint), trace[n] - 1, false)
end
function location()
    func, file, line = frame(3)[end][1:3]
    file = string(file)
    rel_file = relpath(file, PKG_DIR)
    if length(rel_file) < length(file)
        file = rel_file
    end
    "$func[$file:$line]"
end

"""Produces a simple function call lineage summary from the stack trace"""
function lineage(skip::Int=0; ignore_base::Bool=true)
    result = Tuple[]
    frames = stacktrace()
    for (i, frame) in enumerate(frames)
        file = string(frame.file)
        if i <= skip + 1
            continue
        elseif !Base.isidentifier(frame.func)
            # don't show anonymous functions
            continue
        elseif frame.line <= 0
            continue
        elseif frame.func in [:include_from_node1, :eval]
            # stop once we hit julia low-level internals
            break
        elseif ignore_base && !isabspath(file)
            # ignore julia base functions
            continue
        end
        rel_file = relpath(file, PKG_DIR)
        if length(rel_file) < length(file)
            file = rel_file
        end
        push!(result, (frame.func, file, frame.line))
    end
    join((@sprintf("%s[%s:%d]", x...) for x in result), "|")
end

"""Recursively converts dictionary key/value types"""
#function deepconvert{K, V, S <: Associative{K, V}}(T::Type{S}, x::Any)
function deepconvert{K, V}(T::Type{Dict{K, V}}, x::Any)
    if isa(x, Associative)
        T(convert(K, k) => deepconvert(T, v) for (k, v) in x)
    elseif isa(x, AbstractVector)
        map((a) -> deepconvert(T, a), x)
    else
        convert(V, x)
    end
end

"""Recursively merge dictionaries"""
#function deepmerge{K, V, T <: Associative{K, V}}(x::T, y::T)
function deepmerge{K, V}(x::Dict{K, V}, y::Dict{K, V})
    result = filter((k, v) -> !haskey(x, v), y)
    for (k, v) in x
        if !haskey(y, k)
            result[k] = v
            continue
        end
        w = y[k]
        result[k] = (isa(v, Associative) && isa(w, Associative)) ? deepmerge(v, w) : w
    end
    result
end
deepmerge{T}(x::T, y::T, z::T...) = deepmerge(deepmerge(x, y), z...)

"""Backoff attempts of `task` exponentially"""
function backoff(task::Function, check::Function, max_attempts::Int, max_backoff::TimePeriod)
    max_backoff = Millisecond(max_backoff)
    for attempt = 1:max(max_attempts, 1)
        result = task()
        if (result !== nothing) && check(result)
            break
        elseif attempt < max_attempts
            delay = min(Millisecond(2 ^ attempt + floor(rand() * 1000)), max_backoff)
            warn("Unable to complete request: Retrying ($attempt/$max_attempts) in $delay")
            sleep(delay / Millisecond(Second(1)))
        else
            warn("Unable to complete request: Stopping ($attempt/$max_attempts)")
        end
    end
end

"""Dictionary of regex captures from match"""
function matchdict(m::RegexMatch)
    if m === nothing
        return Dict{Symbol, String}()
    end
    Dict{Symbol, String}(
        Symbol(name) => m.captures[i]
        for (i, name) in Base.PCRE.capture_names(m.regex.regex)
    )
end

"""Extracts tokens from an expression."""
function find_tokens(x::Expr, shadow::Vector{Symbol}=Symbol[])
    args = copy(x.args)
    shadow = copy(shadow)
    if x.head == :call
        shift!(args)  # ignore function name
    elseif x.head == :generator
        for vars in filter((arg) -> arg.head == :(=), args)
            vars = first(vars.args)
            if isa(var, Symbol)
                push!(shadow, vars)
            else
                append!(shadow, vars.args)
            end
        end
    elseif x.head == :(->)
        vars = first(args)
        if isa(vars, Symbol)
            push!(shadow, vars)
        else
            append!(shadow, vars.args)
        end
    elseif x.head == :line
        return Symbol[]
    end
    unique(s for arg in args for s in find_tokens(arg, shadow))
end
find_tokens(x::Any, shadow::Vector{Symbol}) = Symbol[]  # drop everything else!
find_tokens(x::Symbol, shadow::Vector{Symbol}) = Base.isidentifier(x) && !in(x, shadow) ? [x] : Symbol[]

"""Makes a complex string template function from a format string (including expressions)"""
function make_template(format::AbstractString; names::Vector{Symbol}=Symbol[])
    body = parse("\"$format\"")
    tokens = find_tokens(body)
    tokens = filter!((x) -> !isdefined(Base, x), tokens)  # get rid of any Base entities (e.g. Int)
    if !isempty(names)
        extra = setdiff(tokens, names)
        if !isempty(extra)
            error("Unsupported names in format: ", join(extra, ", "))
        end
        tokens = names
    end
    kwargs = [Expr(:kw, token, nothing) for token in tokens]
    push!(kwargs, Expr(:..., :_))
    eval(current_module(), Expr(:(->), Expr(:tuple, Expr(:parameters, kwargs...)), body))
end

"""
Makes a simple string parser function from a format string.

Note: Won't consider expressions!
"""
function make_parser(format::AbstractString)
    pattern = replace(format, r"\$([a-zA-Z]\w*|\([a-zA-Z]\w*\))", s"(?<\1>.+)")
    pattern = Regex("^$(pattern)\$")
    (x) -> convert(Dict{Symbol, Any}, matchdict(match(pattern, chomp(x))))
end

"""
Find the indices of the dates nearest to the provided grid, searching from
the end given by the sample direction
"""
function coarsen{S <: TimeType, T <: TimeType}(dates::AbstractVector{S}, grid::AbstractVector{T};
    sample::Union{ForwardOrdering, ReverseOrdering{ForwardOrdering}}=Reverse, missing::Bool=false
)
    result = Int[]

    if isempty(dates)
        return result
    end

    check = sample === Forward ? 1 : -1
    action! = sample === Forward ? push! : unshift!

    perm = sortperm(dates; order=sample)
    dates = collect(zip(dates[perm], perm))
    grid = sort(grid; order=sample)
    grid = zip(grid[1:(end - 1)], grid[2:end])

    # move through grid
    for (start, finish) in grid
        found = false
        while !isempty(dates)
            x, i = shift!(dates)
            s, f = cmp(x, start), cmp(x, finish)
            if (f == check) || (f == 0)
                # out of range. keep until later
                unshift!(dates, (x, i))
                if missing
                    action!(result, 0)
                end
                break
            elseif (s == check) || (s == 0)
                # in range. discard all but the "first" (relative to direction)
                if !found
                    action!(result, i)
                    found = true
                end
            end
        end
        if isempty(dates)
            break
        end
    end
    result
end

end
