# marten_mcp

A Marten implementation of the Model Context Protocol wire format for a
stateless, tools-only server: the JSON-RPC envelope, the Streamable HTTP
mirrored headers, protocol version negotiation, and the dispatcher that turns
a parsed request into a serialized reply. It speaks three revisions at once —
2026-07-28, which dropped the `initialize` handshake and sessions in favor of
every request declaring its own version, alongside the two legacy revisions it
superseded, 2025-11-25 and 2025-06-18, which still expect that handshake. Nothing
is kept between requests either way, and the only capability offered is tools —
no resources, no prompts.

## What it is not

No credential model, no audit table, no admin UI, no tenancy enforcement.
Those are yours.

The shard owns the wire and the request lifecycle. The consuming application
owns identity, authorization, tenancy, persistence, and the tools themselves.
Concretely: no models, no migrations, no `Marten::App` — the shard ships no
schema. `AccessToken` stays in your application. `CallLog` stays in your
application. There is no per-object authorization scaffolding — see "Tenancy
is yours" below. There is no admin UI for tokens or audit rows. This boundary
is deliberate: adding the shard should mean "add the dependency, subclass one
handler, implement two methods" — not "install an app and run a migration."

**One endpoint per application.** `Registry` and the four settings are
process-global, so two routed subclasses in one app necessarily share one tool
list and one server identity. Nothing stops you routing a second subclass — the
handler is abstract, so it looks like an invitation — but it will not give you
a second, independently-scoped endpoint. If you need per-tenant or per-audience
tool sets, express that through `Caller#can?`, which is filtered per request,
rather than through a second endpoint.

## Install

```yaml
# shard.yml
dependencies:
  marten_mcp:
    github: stevegeek/marten-mcp
    version: ~> 0.1.0
```

```crystal
# src/project.cr
require "marten_mcp"
```

## Settings

Set them from wherever your app configures its shards — an initializer such as
`config/initializers/mcp.cr` is the convention in Marten apps that keep one
file per shard.

Use the typed `Marten::MCP.settings` accessor shown here. **`config.mcp.server_name = …`
inside `Marten.configure` does not compile**: Marten's `namespace` macro
generates `def mcp : ::Marten::Conf::Settings`, returning the base class, which
carries none of these setters.

```crystal
# config/initializers/mcp.cr
Marten::MCP.settings.server_name = "myapp"
Marten::MCP.settings.server_version = "1.0.0"
Marten::MCP.settings.instructions = "Call list_orders before edit_order."
Marten::MCP.settings.log_source = "mcp"
```

Four properties, all under the `mcp` settings namespace, read through the
typed `Marten::MCP.settings` accessor:

- `server_name` / `server_version` — identify this server in `initialize`'s
  result and in `server/discover`'s `_meta`. Default to `"marten-mcp"` /
  `"0.0.0"`; set both to your own application's identity.
- `instructions` — free text shown to the model. `nil` by default, and `nil`
  means the field is OMITTED from the response rather than sent as an empty
  string — an absent field and an empty one read differently to a client.
- `log_source` — where this shard's own log lines land. It exists so an
  extracted endpoint's logs keep landing where your operators already look,
  rather than moving out from under an existing alert the day you adopt this
  shard. Set it to the source your application already filters on.

One setting outside these four still matters: Marten's own
`config.allowed_hosts` is what `mcp_origin_failure` matches an incoming
`Origin` against.

It applies only to requests that actually carry an `Origin` header. Browsers
always send one, so `allowed_hosts` is load-bearing in production: it is what
makes the Origin check a real defence against DNS rebinding rather than a
formality. Command-line clients usually send none, and neither does Marten's
own spec client, so a plain integration spec passes whatever `allowed_hosts`
holds.

Set it correctly for your deployment. Specs that exercise the Origin path must
set it themselves, as this shard's `origin_spec.cr` does.

## The hooks

Subclass `Marten::MCP::EndpointHandler`, implement the two required hooks, and
route it:

```crystal
class Mcp::EndpointHandler < Marten::MCP::EndpointHandler
  # REQUIRED in every subclass — see below.
  protect_from_forgery false

  def mcp_remote_ip : String?
    request.headers["X-Forwarded-For"]?
  end

  def mcp_ip_rate_limited?(ip : String?) : Bool
    return false unless Auth.ip_rate_limited?(ip)
    ::Log.for("mcp").warn { "MCP request rejected: IP rate limit exceeded (ip=#{ip || "unknown"})" }
    true
  end

  def mcp_authenticate(request, ip) : Marten::MCP::Caller | Marten::MCP::AuthFailure
    Auth.resolve(request, ip)
  end

  def mcp_audit(record : Marten::MCP::CallRecord) : Nil
    CallLog.record(
      caller: record.caller, ip: record.ip, rpc_method: record.rpc_method,
      tool_name: record.tool_name, outcome: record.outcome,
      error_code: record.error_code, arguments: record.arguments,
      summary: record.summary, duration_us: record.duration_us,
      client_name: record.client_name, client_version: record.client_version,
      protocol_version: record.protocol_version)
  end
end
```

```crystal
# config/routes.cr
Marten.routes.draw do
  path "/mcp", Mcp::EndpointHandler, name: "mcp"
end
```

Two hooks are REQUIRED; four are optional and have defaults:

| Hook | Required | Default |
|---|---|---|
| `mcp_remote_ip : String?` | yes | — the shard cannot guess which proxy headers you trust |
| `mcp_authenticate(request, ip) : Caller \| AuthFailure` | yes | — identity is entirely yours |
| `mcp_ip_rate_limited?(ip) : Bool` | no | `false` — no rate limiting |
| `mcp_audit(record) : Nil` | no | no-op — no audit trail |
| `mcp_origin_failure : AuthFailure?` | no | `Marten::MCP::Origin.failure(request)` |
| `mcp_dispatcher(caller) : Protocol::Dispatcher` | no | `Protocol::Dispatcher.new(caller)` |

### Serving a method this shard does not implement

`mcp_dispatcher` is the seam for that. Subclass `Dispatcher`, handle your own
method names, delegate the rest to `super`:

```crystal
class MyDispatcher < Marten::MCP::Protocol::Dispatcher
  def call(envelope : Marten::MCP::Protocol::Envelope) : Outcome
    return resources_list(envelope) if envelope.method == "resources/list"
    super
  end

  private def resources_list(envelope) : Outcome
    Outcome.new(%({"jsonrpc":"2.0","id":1,"result":{"resources":[]}}), 200, "ok")
  end
end

class Mcp::EndpointHandler < Marten::MCP::EndpointHandler
  def mcp_dispatcher(caller : Marten::MCP::Caller) : Marten::MCP::Protocol::Dispatcher
    MyDispatcher.new(caller)
  end
end
```

Your method is then audited by the same single code path as a built-in one.
Without this seam the only way to add a method would be to reimplement `post`,
and with it the audit contract and the double-row guard — the two things most
worth not rewriting.

Every hook is `mcp_`-prefixed on purpose. A consumer handler typically mixes in
its own concerns — a `RemoteIp` module, an `Auth` service — and an unprefixed
abstract method (just `remote_ip`, say) could be satisfied by accident, by
whichever included module happens to already define a method with that name.
The prefix keeps the shard's own contract distinguishable from whatever else
the subclass has mixed in.

### `protect_from_forgery false` is required

`@@protect_from_forgery` is per-class storage in Crystal — declaring it on the
abstract `EndpointHandler` would not reach a subclass that is actually routed,
because each subclass gets its own copy of that class variable. Every subclass
must declare it for itself, or every request against it 403s.

Bearer-only authentication is what makes the exemption honest rather than a
hole: CSRF protection exists to stop a cross-site request from riding a
browser's ambient session cookie. This endpoint never reads the session
cookie — `mcp_authenticate` is the only source of identity — so a cross-site
POST has no ambient authority to borrow, and the forgery check has nothing to
protect against.

### The `::Log` gotcha

Marten defines `Log = ::Log.for("marten")` (`marten.cr:46`). A bare
`Log.for("x")` written lexically inside `module Marten::MCP`, or inside a
handler subclass that itself sits inside a `Marten::` namespace, resolves to
Marten's own `Log` constant rather than the top-level `::Log`, and emits under
`marten.x` — not `x`. This shard's own catch-all rescue writes
`::Log.for("#{Marten::MCP.settings.log_source}.endpoint")` for exactly this
reason. When one of your hooks logs — `mcp_ip_rate_limited?`, most often —
write `::Log.for(...)`, not `Log.for(...)`, if the method sits inside a
`Marten::` namespace. This fails SILENTLY: nothing raises, the line simply
lands under a source nobody is watching.

## Writing a tool

Subclass `Marten::MCP::Tool`, register an instance, done:

```crystal
class Tools::Ping < Marten::MCP::Tool
  def name : String
    "ping"
  end

  def title : String
    "Ping"
  end

  def description : String
    "Round-trips a message back to the caller."
  end

  def capability : Symbol
    :read
  end

  def input_schema : String
    %({"type":"object","properties":{"message":{"type":"string"}},"required":["message"]})
  end

  def call(caller : Marten::MCP::Caller, args : Marten::MCP::Args) : Marten::MCP::ToolResult
    Marten::MCP::ToolResult.new(text: args.string("message"))
  end
end

Marten::MCP::Registry.register(Tools::Ping.new)
```

`capability` is a `Symbol` from your own application's vocabulary. The
registry hides a tool from a caller whose `can?` returns false for it, and the
dispatcher checks `can?` again before running the tool — the list is a
courtesy, the call check is the gate. Register every tool once, at boot (an
initializer, or the bottom of the file that defines it): `Registry.all` and
`Registry.visible_for` read a single process-global list.

Four more methods have defaults you can override: `output_schema` (`nil`),
`read_only?` (`true`), `destructive?` (`false`), `idempotent?` (follows
`read_only?`).

`Args` gives typed access to `arguments`: `args.string("message")`,
`args.string?("message")`, `args.bool?("force")`, `args.int?("limit")`, and
`args.int("limit", default: 20, max: 100)`. The first four raise
`Args::Invalid` on a wrong type or a missing required field, which the
dispatcher turns into a `-32602` naming the field. `int` with bounds is the
exception: it CLAMPS instead of raising, because a model that asks for a
thousand rows should get the maximum and a cursor, not an error to reason
about.

**Reflect caller input back through `Echo.cap`.** Anything you echo into an
error message — a bad tag, an unparseable cursor, a tool name — reaches both
the JSON-RPC error and your audit row, and an uncapped 3,000-character argument
arrives whole and is stored whole:

```crystal
return ToolResult.error("Unknown tag '#{Marten::MCP::Echo.cap(tag)}'.")
```

It bounds size, not content; escaping is already handled either way.

## Tenancy is yours

This shard performs NO tenancy check. `caller.can?(:edit_orders)` answers "may
this caller edit orders", never "may this caller edit *this* order" — the
capability vocabulary has no concept of a specific row, only of an action. A
shard-level API that looked like it answered the second question would be
worse than none, because a consumer would trust it.

What the shard gives you instead is the `Caller` itself, passed to every
tool's `call`. The recommended pattern is a base tool class that narrows it to
your own context type exactly once, with `as?` — never `as`, since a wrong
type must degrade to a clear tool error, not a 500:

```crystal
abstract class Tools::TenantTool < Marten::MCP::Tool
  def call(caller : Marten::MCP::Caller, args : Marten::MCP::Args) : Marten::MCP::ToolResult
    context = caller.as?(MyApp::Context)
    return Marten::MCP::ToolResult.error("Tool unavailable for this caller") if context.nil?
    call(context, args)
  end

  abstract def call(context : MyApp::Context, args : Marten::MCP::Args) : Marten::MCP::ToolResult
end
```

Every tool below `TenantTool` then receives a fully-typed context — carrying
`context.account`, say — and is responsible for rooting its own queries in it:

```crystal
Order.filter(account_id: context.account.pk)
```

Do the narrowing once, in this one base class, not once per tool: one downcast
to audit rather than one per tool file.

## The audit contract

`mcp_audit` is called exactly once per request — including a request that
failed before it reached a tool, which are the ones an audit trail exists for
in the first place: a bad Origin, a failed authentication, a malformed
JSON-RPC envelope, a header mismatch, an internal error. Every one of those
produces a `CallRecord` and a call to your hook, the same as a successful
`tools/call`.

The one deliberate exception is the IP rate-limit rejection —
`mcp_ip_rate_limited?` returning `true`. That request is never audited. The
check runs before authentication specifically so an unauthenticated caller
cannot flood your audit table; writing a row for every rejected request here
would defeat the check by charging the flood protection to the very table it
exists to protect. The shard also emits no log line for this rejection: your
`mcp_ip_rate_limited?` should log it, naming the IP, since at that point the
log line is the event's only record — and the hook already knows it is about
to reject, which is why the example above logs from inside it.

## Status

Extracted from a production Marten application and released as `v0.1.0`. It has
one real consumer, so treat the seams as provisional: the hooks are what that
application needed, and a second consumer may well want a shape this version
cannot express. Open an issue rather than working around it.

Deliberately out of scope for v1, and the most likely additions: per-object
authorization (`can?` answers "may this caller edit orders", never "may this
caller edit *this* order"), an optional reference credential model, and a
redaction seam for tools that return personal data.
