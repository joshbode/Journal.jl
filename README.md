Journal Logging Framework
-------------------------

Journal.jl is an extensible hierarchical logging framework for Julia with
multiple output targets, including:

- Streams: Console, File, etc
- Google Datastore (via [GoogleCloud.jl](https://github.com/joshbode/GoogleCloud.jl))
- Arbitrary webhook APIs (e.g. Slack) with ability to authenticate via custom
  methods

Loggers can be configured hierarchically, with child loggers set to log at different
levels or to different targets.

Data stored by Journal.jl can also be read back later from a specific store.

# Basic Usage

Journal.jl is generally configured via YAML. The YAML format specifies:

- `stores` with associated:
  - store `type`: e.g. `io`, `datastore`, `webhook` or some custom registered type
  - plus configuration relevant to the specific store type
- `loggers` with associated:
  - log `level`: (`DEBUG < INFO < WARN < ERROR`)
  - target `stores`: referencing a store definition
  - dependent `children`: referencing child loggers that are to be passed the same messages as the parent

Here is a simple configuration file:
```yaml
# journal.yml
stores:
  console:
    type: io
  file:
    type: io
    file: [journal.log, w+]
    format: "$timestamp: $level: $name: topic=$topic; message=$message; value=$value"
loggers:
  screen:
    level: DEBUG
    stores: [console]
    children: [disk]
  disk:
    level: INFO
    stores: [file]
```

Journal can now be set up from the configuration file:
```julia
using Journal
Journal.config("journal.yml")
```

Use the loggers:
```julia
# use default "root" logger (screen)
Journal.info("Is this thing on?")

# specify topic (overrides line func[file:line])
Journal.info("Helllloooooo"; topic="greeting")

# attach a value to the message
Journal.info("Testing, Testing"; value=[1, 2, 3], topic="mic_check")
Journal.warn("Check"; value=[1, 2], topic="mic_check")

# override the timestamp
Journal.info("A long time ago in a galaxy far far away..."; timestamp=DateTime("1977-05-25"), topic="star wars")

# add custom tags
Journal.info("Exterminate"; topic="threat", species="dalek", source="Davros")

# log to a specific logger
logger = getlogger(:screen)
Journal.debug(logger, "Can you hear me?")  # note: not stored to "disk" logger since DEBUG < INFO

# or using a do block
getlogger(:disk) do logger
    Journal.warn(logger, "Don't touch that!")
    Journal.error(logger, "ZAP")
end
```

Journal can also read back log data:
```julia
using DataTables
using Base.Dates

store = getstore(:file)
records = read(store)
table = DataTable(records)

# apply a filter to the data
mic_checks = read(store; filter=Dict(:topic => "mic_check"))

# apply a timestamp filter [start, finish]
recent = read(store; start=now(UTC) - Day(1), finish=now(UTC))
```

# Remote Logging

Journal.jl can also log to remote targets such as Google Datastore and to
webhook APIs.

## Google Datastore

Google Datastore requires a Google Cloud Platform service account credentials
JSON file.

```yaml
# journal.yml
loggers:
  root:
    level: DEBUG
    stores: [datastore]
stores:
  datastore:
    credentials: credentials.json
```

See [GoogleCloud.jl](https://github.com/joshbode/GoogleCloud.jl) for more
detail about getting service account credentials configured.

## Webhook API

Journal.jl can post to an arbitrary webhook URI.

For example, to log simple messages to a slack channel, obtain `uri` by configuring an
[incoming webhook](https://my.slack.com/services/new/incoming-webhook) and using
`key_map` to map the message to the `text` key:

```yaml
loggers:
  ...
stores: 
  slack:
    type: webhook
    uri: https://hooks.slack.com/services/XXXXXXXXX/YYYYYYYYY/ABCDEFGHIJKLMNOPQRSTUVWX
    use_tags: false
    key_map:
      text: message
```

All of the standard log record fields (`timestamp`, `hostname`, `level`,
`name`, `topic`, `value`, `message`) are available to be mapped.

Note: `use_tags: false` prevents any custom tags set at log-time from being
automatically mapped (which breaks the Slack API).

### Custom Authenticator

For APIs requiring authentication (e.g. OAuth 2.0, etc), a custom authenticator
can be added.

In this example, the `Authorization` header is set on every request, based on
some `key` and a hypothetical `generate_token` function.

```yaml
stores:
  service:
    type: webhook
    uri: https://example.com/log
    key_map:
      timestamp: timestamp
      hostname: hostname
      name: name
      topic: topic
      value: value
      level: level
      message: message
    authenticator:
      type: CustomAuthenticator
      key: purplemonkeydishwasher
```

```julia
using Journal
import Journal.store.webhook: Authenticator

immutable CustomAuthenticator <: Authenticator
    key::String
    function CustomAuthenticator(key::AbstractString)
        new(password)
    end
end
function CustomAuthenticator(data::Dict{Symbol, Any})
    CustomAuthenticator(data[:key])
end

"""Adds "Authorization" header to request headers"""
function (a::CustomAuthenticator)(headers::Dict{String, Any}, query::Dict{Symbol, Any})
    token = generate_token(now(), a.key)  # e.g. generate some time-dependent token
    headers["Authorization"] = token
    nothing
end

# config must be after CustomAuthenticator is defined
Journal.config("journal.yml")
...
```

# Default Loggers

Journal.jl will automatically derive a root logger and assign it as the default
logger. However, in the case where there are multiple possible root loggers one
of the loggers will be (arbitrarily) assigned as the default.

If a specific (or even non-root) logger needs to be chosen as the default, the
`default` key in the configuration file can be specified.

In this example, there are two possible root loggers (`A` and `C`). Logger `A`
has been specified as the default.

```yaml
# journal.yml
default: A
loggers:
  A:
    level: DEBUG
    stores: [X]
    children: [B]
  B:
    level: INFO
    stores: [Y]
  C:
    level: INFO
    stores: [Z]
stores:
  X:
    ...
  Y:
    ...
  Z:
    ...
```


# Namespaces

Multiple packages are able to use Journal.jl independently, and Namespaces can be
used to ensure separation between loggers and stores configuration.

```yaml
# journal-foo.yml
namespace: [foo]
loggers:
  screen:
    ...
stores:
  console:
    ...
```

```yaml
# journal-bar.yml
namespace: [bar]
loggers:
  screen:
    ...
stores:
  console:
    ...
```

```julia
using Journal
Journal.config("journal-foo.yml")
Journal.config("journal-bar.yml")

foo_logger = getlogger([:foo])
bar_logger = getlogger([:bar])
...
```

Note: the default namespace is `[]`.

# Extending Journal

Journal can be extended by registering new store types derived from the `Store`
abstract type. The `write` method must be implemented, and optionally `read`.

```julia
using Journal

immutable FooStore <: Store
    ...
end
function Base.write(store::FooStore,
    timestamp::DateTime, hostname::AbstractString, level::LogLevel, name::Symbol, topic::AbstractString,
    value::Any, message::Any; async::Bool=true, tags...
)
    ...
end
function Base.read{T <: Any}(store::FooStore;
    start::Union{TimeType, Void}=nothing, finish::Union{TimeType, Void}=nothing,
    filter::Associative{Symbol, T}=Dict{Symbol, Any}()
)
    ...
end

register(FooStore, :foo)
```
