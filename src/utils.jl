module utils

export
    location, frame, show_error,
    backoff,
    deepconvert, deepmerge,
    matchdict, make_template, make_parser,
    coarsen

using Base: Dates, Order

function check(x)
    info = ccall(:jl_lookup_code_address, Any, (Ptr{Void}, Cint), x - 1, false)
    info[1][1] == Symbol("")
end

"""Captures error messages and optionally the backtrace."""
function show_error(e::Exception; backtrace=true)
    if backtrace
        trace = catch_backtrace()
        sprint((io) -> showerror(io, e, trace))
    else
        sprint((io) -> showerror(io, e))
    end
end


PKG_DIR = Pkg.dir()
CUR_DIR = pwd()

function location(n=4)
    trace = ccall(:jl_backtrace_from_here, Vector{Ptr{Void}}, (Int32, ), false)
    x = last(ccall(:jl_lookup_code_address, Any, (Ptr{Void}, Cint), trace[n] - 1, false))
    func, file, line = x[1:3]
    file = string(file)
    if splitext(file)[2] == ".jl"
        pkg_file = relpath(file, PKG_DIR)
        cur_file = relpath(file, CUR_DIR)
        file = first(sort([file, pkg_file, cur_file]; by=(x) -> (isabspath(x), length(x))))
    elseif !ismatch(r"^REPL\[\d+\]$", basename(file))
        func, file, line = "", "", -1
    end
    "$func[$file:$line]"
end

"""Recursively converts dictionary key/value types"""
function deepconvert(T::Type{<: Associative{K, V}}, x::Any) where {K, V}
    if isa(x, Associative)
        T(convert(K, k) => deepconvert(T, v) for (k, v) in x)
    elseif isa(x, AbstractVector)
        map((a) -> deepconvert(T, a), x)
    else
        convert(V, x)
    end
end

"""Recursively merge dictionaries"""
function deepmerge(x::Associative, y::Associative)
    K, V = Union{keytype(x), keytype(y)}, Union{valtype(x), valtype(y)}
    result = Dict{K, V}(k => v for (k, v) in y if !haskey(x, v))
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
deepmerge(x::Associative, y::Associative, z::Associative...) = deepmerge(deepmerge(x, y), z...)

"""Backoff attempts of `task` exponentially"""
function backoff(task::Function, check::Function, max_attempts::Int, max_backoff::TimePeriod)
    max_backoff = Millisecond(max_backoff)
    for attempt = 1:max(max_attempts, 1)
        result = task()
        if (result !== nothing) && check(result)
            break
        elseif attempt < max_attempts
            delay = min(Millisecond(floor(Int, 1000 * (2 ^ (attempt - 1) + rand()))), max_backoff)
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
    pattern = replace(format, r"\$([a-zA-Z]\w*|\([a-zA-Z]\w*\))", s"(?<\1>.*)")
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
