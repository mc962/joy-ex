# Architecture Overview

Joy is an HL7 v2.x integration engine: it receives HL7 messages over MLLP (TCP), applies user-defined transforms, and forwards them to one or more destinations. This document describes how it is structured, why key decisions were made, and how the pieces fit together.

## Contents

- [The Channel Model](#the-channel-model)
- [Message Flow](#message-flow)
- [OTP Supervision Tree](#otp-supervision-tree)
- [At-Least-Once Delivery](#at-least-once-delivery)
- [Transform System](#transform-system)
- [Destinations](#destinations)
- [HL7 Representation](#hl7-representation)
- [Clustering](#clustering)
- [Web Interface](#web-interface)
- [REST API](#rest-api)
- [Service Accounts](#service-accounts)
- [Dispatch Concurrency](#dispatch-concurrency)
- [Organizations](#organizations)
- [Message Log Retention](#message-log-retention)
- [Audit Logging](#audit-logging)
- [Data Model](#data-model)

---

## The Channel Model

A **channel** is the fundamental unit of work in Joy. Each channel represents a single intake point: it listens on a dedicated TCP port for incoming MLLP connections, applies a sequence of transform scripts, and delivers the result to one or more destinations.

Channels are independent. A crash in channel A — its transform script, its MLLP server, its destinations — cannot affect channel B. This isolation is enforced structurally at the process level, not by convention.

At runtime, each channel is an isolated OTP supervisor tree containing three components:

- **WorkerSupervisor** — a `Task.Supervisor` that owns the worker tasks executing message processing. By keeping it separate from the Pipeline, task crashes cannot crash the Pipeline GenServer.
- **Pipeline** — the processing brain. Holds the channel's config (transforms, destinations) in memory. Dispatches messages to worker tasks via WorkerSupervisor; tracks `in_flight` count and a local pending queue to enforce `dispatch_concurrency`. Supports pause/resume: when paused, new dispatches are held in the DB as `:pending` and the MLLP server keeps accepting.
- **MLLP.Server** — the TCP listener backed by ThousandIsland. Accepts plain TCP or TLS connections, runs up to 100 concurrent TLS handshakes via ThousandIsland's acceptor pool, and hands each accepted connection to a `Joy.MLLP.Connection` handler.

All three run under a per-channel `:rest_for_one` supervisor. If the Pipeline crashes, the Pipeline and MLLP.Server restart together (the Server needs a live Pipeline to dispatch to); the WorkerSupervisor is not restarted so orphaned tasks can finish naturally. If only the Server crashes, only the Server restarts — the Pipeline's state is preserved.

---

## Message Flow

A message travels through the following steps from TCP bytes to delivered result:

```
TCP client (upstream HL7 system)
      │
      │  [raw TCP bytes]
      ▼
Joy.MLLP.Server           — accepts the connection, spawns a Connection process
      │
      │  [socket handed off]
      ▼
Joy.MLLP.Connection       — one process per active TCP connection
      │
      ├─ 1. Buffer incoming bytes until a complete MLLP frame arrives
      │      MLLP frame: 0x0B <HL7 bytes> 0x1C 0x0D
      │
      ├─ 2. Parse the HL7 message → %Message{segments: [...], ...}
      │
      ├─ 3. Persist to message_log as :pending   ◄── BEFORE sending ACK
      │      (extracts message_type from MSH.9 and patient_id from PID.3 for search)
      │
      ├─ 4. Send ACK (AA = accepted, AE = error)
      │
      └─ 5. Cast entry_id to Pipeline (async)
                  │
                  ▼
      Joy.Channel.Pipeline
                  │
                  ├─ 6. Re-fetch the entry from DB (ensures idempotency across restarts)
                  │
                  ├─ 7. Parse the raw_hl7 from the entry
                  │
                  ├─ 8. Run transform scripts in order
                  │      Each script: validate → sandbox → execute → updated %Message{}
                  │
                  ├─ 9. Deliver to destinations (those enabled, or those named by route/2)
                  │      Each delivery: adapter.deliver/2 with exponential retry
                  │
                  └─ 10. Mark entry as :processed (or :failed) in message_log
```

Steps 3 and 4 are ordered deliberately — see [At-Least-Once Delivery](#at-least-once-delivery).

Step 5 is asynchronous (`GenServer.cast`): the Connection does not wait for processing to complete before handling the next message. The Pipeline never blocks on I/O — it dispatches each message to a worker task via `Joy.Channel.WorkerSupervisor` and immediately returns to handle the next incoming cast. The `dispatch_concurrency` channel setting (default 1) controls how many tasks may run simultaneously; see [Dispatch Concurrency](#dispatch-concurrency).

---

## OTP Supervision Tree

```
Joy.Supervisor  (:one_for_one)
│
├── JoyWeb.Telemetry           Phoenix metrics
├── Joy.Repo                   Ecto/Postgres connection pool
├── DNSCluster                 Connects Erlang nodes (queries DNS_CLUSTER_QUERY)
├── Phoenix.PubSub             Real-time pub/sub (pg adapter — works across cluster)
│
├── Joy.ChannelRegistry        Horde.Registry — distributed process registry
│                              Keys: channel_id → Channel.Supervisor PID
│                                    {:pipeline, channel_id} → Pipeline PID
│                                    {:workers, channel_id} → WorkerSupervisor PID
│
├── Joy.TransformSupervisor    Task.Supervisor — sandboxed script execution (node-local)
├── Joy.ChannelStats           GenServer — ETS-backed per-channel throughput counters (node-local)
├── Joy.Alerting               GenServer — ETS-backed consecutive failure tracking + alert delivery (node-local)
├── Joy.CertMonitor            GenServer — daily TLS cert expiry check; fires alerts via Joy.Alerting (node-local)
├── Joy.Retention.Scheduler    GenServer — hourly tick; fires daily message log purge at configured UTC hour (node-local)
├── Joy.Sinks                  GenServer — in-memory test sink (node-local)
│
├── Joy.ChannelSupervisor      Horde.DynamicSupervisor — distributed channel trees
│   │
│   ├── Joy.Channel.Supervisor  [channel 1]  (:rest_for_one)
│   │   ├── [0] Joy.Channel.WorkerSupervisor  Task.Supervisor — worker tasks for concurrent dispatch
│   │   ├── [1] Joy.Channel.Pipeline          GenServer — dispatch control and stats
│   │   └── [2] Joy.MLLP.Server               ThousandIsland — TCP/TLS listener (100 acceptors)
│   │       └── Joy.MLLP.Connection           ThousandIsland.Handler — one per active connection
│   │
│   ├── Joy.Channel.Supervisor  [channel 2]  (:rest_for_one)
│   │   ├── [0] Joy.Channel.WorkerSupervisor
│   │   ├── [1] Joy.Channel.Pipeline
│   │   └── [2] Joy.MLLP.Server
│   │
│   └── ...  (one tree per started channel, distributed across cluster nodes)
│
├── Joy.ChannelManager         GenServer — lifecycle control plane
└── JoyWeb.Endpoint            Phoenix HTTP/WebSocket endpoint
```

**Why `:one_for_one` at the top?** Each child serves a completely different function. A crashed Repo should not restart the PubSub; a crashed Endpoint should not restart ChannelManager. Every child is independent.

**Why `:rest_for_one` per channel?** The Pipeline must be alive before the MLLP.Server can dispatch messages to it. If the Pipeline crashes, the Server is also restarted so it connects to the fresh Pipeline. If only the Server crashes (e.g., port conflict on restart), the Pipeline's in-memory stats and cached config are preserved. The WorkerSupervisor sits at index [0] so it is not restarted when the Pipeline crashes — this allows in-flight worker tasks to complete and send their results to the old (dead) Pipeline pid, which are silently dropped; the new Pipeline requeues those entries from the DB on startup.

**Why ThousandIsland for MLLP.Server?** ThousandIsland is already a dependency (via Bandit) and provides a battle-tested acceptor pool that handles concurrent TLS handshakes correctly. The previous hand-rolled acceptor loop serialized TLS handshakes — one at a time — which caused connection timeouts under burst load. ThousandIsland runs 100 acceptor processes against the same listen socket, so up to 100 handshakes proceed simultaneously with no coordination overhead. `Joy.MLLP.Connection` is now a plain `ThousandIsland.Handler` with data arriving via callbacks instead of active-mode process messages.

**`ChannelManager`** is not the supervisor — it is a GenServer that provides the `start_channel/1`, `stop_channel/1`, `pause_channel/1`, and `resume_channel/1` API. On startup it reads `started: true` channels from the database and starts their OTP trees via `Horde.DynamicSupervisor`. The ChannelManager runs on every node; Horde deduplicates.

**`ChannelStats` and `Alerting`** are node-local GenServers backed by ETS. `ChannelStats` tracks received/processed/failed counts per channel per day; `Alerting` tracks consecutive failures and fires email/webhook alerts when a per-channel threshold is exceeded. Both are intentionally node-local: they track ephemeral runtime state that resets on restart, not durable data.

**`CertMonitor`** is a node-local GenServer that runs a TLS certificate expiry check on startup and every 24 hours. It queries channels whose `tls_cert_expires_at` is within 30 days and calls `Joy.Alerting.send_direct/3` to fire an email/webhook alert. Because it reads from the database, it works correctly regardless of which node is running each channel.

**`Retention.Scheduler`** is a node-local GenServer that wakes once per hour and, if the schedule is enabled and the current UTC hour matches `retention_settings.schedule_hour`, triggers `Joy.Retention.run_purge/0` in a background Task. A `last_purge_at` timestamp on the settings row provides coarse duplicate-run protection in multi-node deployments — if two nodes check at the same time and both see the hour match, the second to update `last_purge_at` will find it already set to today on the next check.

---

## At-Least-Once Delivery

Joy guarantees that every accepted HL7 message is delivered to its destinations at least once, even across process crashes or node failures. This is achieved through a simple rule:

> **Persist to the database before sending the ACK.**

The sequence is:
1. Message received over TCP
2. Written to `message_log_entries` with `status: :pending`
3. ACK sent to the upstream sender
4. Processing dispatched asynchronously

If the server crashes at any point after step 2, the message is already in the database. When the Pipeline restarts (either on the same node or on another via Horde), its `init/1` callback immediately queries for all `:pending` entries for its channel and requeues them:

```elixir
def handle_continue(:requeue_pending, state) do
  pending = Joy.MessageLog.list_pending(state.channel.id)
  Enum.each(pending, fn entry -> send(self(), {:cast_process, entry.id}) end)
  ...
end
```

If the server crashes *before* step 2 (before persisting), no ACK is sent. The upstream sender receives no response and retries according to its own retry policy. This is the correct MLLP behavior.

**Deduplication:** Multiple retries of the same message can produce duplicates. Joy handles this with a unique database index on `(channel_id, message_control_id)` and an upsert with `on_conflict: :nothing`. If a message with the same `MSH.10` control ID arrives again for the same channel, it is silently ignored and an ACK is still sent. (Messages without a control ID — a malformed but real-world occurrence — are not deduplicated.)

---

## Transform System

Each channel has an ordered list of **transform steps**. Each step is a small Elixir script that receives a `%Message{}` and returns a modified `%Message{}`. Steps run in sequence; the output of one is the input to the next.

### The DSL

Scripts have access to a small, fixed set of functions:

| Function | Description |
|---|---|
| `get(msg, "PID.5.1")` | Read a field by HL7 dot-path |
| `set(msg, "PID.5.1", value)` | Write a field; returns new message |
| `copy(msg, "PID.3", "ZID.1")` | Copy a field from one path to another |
| `delete_segment(msg, "Z01")` | Remove all segments with a given name |
| `route(msg, "audit_sns")` | Tag message for a specific destination only |
| `log(msg, "text")` | Emit a log line; returns message unchanged |

Plus safe standard library: `String`, `Integer`, `Float`, `List`, `Map`, `Enum`, `Regex`, `DateTime`.

A script looks like this:

```elixir
# Remove SSN from PID.19
msg = set(msg, "PID.19", "")

# Route to audit destination only if this is an ADT message
msg_type = get(msg, "MSH.9")
if String.starts_with?(msg_type || "", "ADT") do
  msg = route(msg, "audit_sns")
end

msg
```

The variable `msg` is always in scope. The final value of `msg` after the script completes becomes the output message.

### Security: AST Whitelist Validation

Because transform scripts are user-supplied code executed on the server, they must be constrained. Joy uses an **AST whitelist validator** (`Joy.Transform.Validator`) that runs before any script is executed.

The validator parses the script into an AST using Elixir's own parser, then walks every node. If any node represents a blocked operation, the script is rejected with an error and never executed. Blocked operations include:

- All non-whitelisted modules (`File`, `System`, `Process`, `Node`, `Port`, `IO`, etc.)
- All Erlang module calls (`:os.cmd`, `:erlang.apply`, etc.)
- Meta-programming (`spawn`, `send`, `import`, `require`, `use`, `quote`)

Validation results are cached in `persistent_term` (keyed by SHA-256 of the script), so identical scripts are only validated once per node lifetime.

### Sandboxed Execution

Validated scripts run inside `Task.Supervisor.async_nolink/2` under `Joy.TransformSupervisor`. Key properties:

- **`async_nolink`**: a crash in the script task does not crash the calling Pipeline GenServer. The pipeline catches the exit and marks the message as `:failed`.
- **5-second timeout**: scripts that loop forever or are otherwise stuck are killed. The Pipeline logs the timeout and moves on.
- **Isolation from channels**: `Joy.TransformSupervisor` is a sibling of `Joy.ChannelSupervisor` in the top-level tree. A catastrophic transform failure cannot affect the supervision of channels.

---

## Destinations

A destination is where a processed message is sent after transforms are applied. Each channel can have multiple destinations. All destinations for a channel receive every message, unless the transform used `route/2` to tag the message — in which case only the named destinations receive it.

Joy ships with seven adapters:

| Adapter | Description |
|---|---|
| `http_webhook` | HTTP POST with configurable headers; supports HMAC signing |
| `aws_sns` | Publish to an AWS SNS topic |
| `aws_sqs` | Enqueue to an AWS SQS queue |
| `mllp_forward` | Forward to another system over MLLP (TCP) |
| `redis_queue` | LPUSH to a Redis list |
| `file` | Append to a file on the server filesystem |
| `sink` | In-memory ring buffer for testing; viewable in the web UI at `/tools/sinks` |

Each adapter implements the `Joy.Destinations.Destination` behaviour:

```elixir
@callback deliver(message :: Joy.HL7.Message.t(), config :: map()) :: :ok | {:error, String.t()}
@callback validate_config(config :: map()) :: :ok | {:error, String.t()}
@callback adapter_name() :: String.t()
```

**Retry:** Delivery is wrapped in `Joy.Destinations.Retry.with_retry/3`, which retries on error with exponential backoff and jitter. Retry attempts and base delay are configurable per destination in the UI. Jitter (a random component added to each sleep) prevents multiple channels from thundering-herd a shared backend simultaneously after it recovers.

**Destination credentials** (API keys, passwords, connection strings) are stored encrypted in the database using AES-256-GCM via a custom Ecto type (`Joy.Encrypted.MapType`). The encryption key is the `ENCRYPTION_KEY` environment variable. The config map is encrypted/decrypted transparently at the Ecto layer; adapters see plaintext.

---

## HL7 Representation

Joy parses HL7 v2.x messages into a `%Joy.HL7.Message{}` struct:

```elixir
%Joy.HL7.Message{
  raw: "MSH|...",          # original bytes, preserved for logging
  segments: [
    %{name: "MSH", fields: ["MSH", "^~\\&", "SendApp", ...]},
    %{name: "PID", fields: ["PID", "", "12345", ...]},
    ...
  ],
  field_sep: "|",          # from MSH.1
  comp_sep:  "^",          # from MSH.2
  rep_sep:   "~",
  esc_char:  "\\",
  sub_sep:   "&",
  routes: []               # populated by route/2 in transforms
}
```

Fields are accessed by **dot-path notation**: `"PID.5.1"` means segment `PID`, field 5, component 1. The accessor (`Joy.HL7.Accessor`) handles missing segments and fields safely, returning `nil` for reads and creating intermediate structure for writes.

The MLLP framer (`Joy.MLLP.Framer`) handles the byte wrapping: `0x0B <message> 0x1C 0x0D`. It is lenient about missing start bytes (handles senders that omit `0x0B`) but strict about frame integrity.

ACK responses are built from the original message's MSH header with sender/receiver fields swapped, using the same field separators the sender used. This is important for interoperability with systems that validate ACK encoding.

---

## Clustering

Joy runs as a multi-node Erlang cluster. Key properties:

**Node discovery** is handled by `DNSCluster` (the `dns_cluster` hex package). On boot, each node queries the DNS name in `DNS_CLUSTER_QUERY` for A records and attempts to connect to each IP as an Erlang node named `joy@<IP>`. The node name `joy@<IP>` is set dynamically in `rel/env.sh.eex` from `hostname -i`.

**Distributed process registry** (`Joy.ChannelRegistry`, a `Horde.Registry`) maps channel IDs to process PIDs. It is queryable from any node in the cluster — a UI request on node A can find the Pipeline PID running on node B.

**Distributed channel supervision** (`Joy.ChannelSupervisor`, a `Horde.DynamicSupervisor`) starts and monitors channel OTP trees across nodes. When a node dies, Horde detects it (via Erlang's `net_ticktime` heartbeat, configured to 30 seconds) and restarts the affected channel trees on surviving nodes.

**Why exactly one node per channel?** Each channel owns a TCP port. Two nodes cannot both bind the same port. Horde's model of running each child on exactly one node matches this constraint naturally. When Horde restarts a channel on a new node, the new node binds the port and begins accepting connections. Upstream senders experience a brief TCP RST on the old connection and reconnect.

**`ChannelManager` runs on every node** but is not a cluster singleton. Every node's ChannelManager independently tries to start all `started: true` channels on boot. `Horde.DynamicSupervisor` deduplicates by child spec ID — the second node to request a channel that's already running gets `{:already_started, pid}`, which the ChannelManager treats as success.

**Phoenix.PubSub** uses the `pg` process group adapter (default since Phoenix 1.6), which works across nodes automatically. LiveView broadcasts (`channel:#{id}:stats`, `message_log:#{id}`) reach all connected browsers regardless of which node the pipeline is running on.

---

## Web Interface

All web routes require authentication. Users can self-register, but freshly registered users cannot access anything meaningful until promoted to admin via `mix joy.make_admin`. Non-admin authenticated users get read-only access to operational views; admin users can make configuration changes.

Authentication uses `phx.gen.auth` (email + password + magic link via email token). Session tokens are stored in the database (`user_tokens` table), so sessions work correctly across a cluster without sticky sessions or shared cookie signing concerns.

### Two-tier live session model

The router splits routes into two Phoenix live sessions:

- **`:app`** — any authenticated user. Covers the dashboard, channel views, org views, and message log pages. Non-admin users see status, stats, and message data but all mutation controls are hidden by template guards and blocked by event handler guards (`admin?(socket)` imported from `JoyWeb.AdminAuth`).
- **`:admin`** — requires `is_admin: true`, enforced by the `JoyWeb.AdminAuth` on-mount hook. Covers `/users`, `/tools/*`, and `/audit`.

`admin?/1` is a public function in `JoyWeb.AdminAuth` imported into all LiveViews via `use JoyWeb, :live_view`. Message retry (`retry`, `retry_all_failed`) is intentionally not admin-gated — on-call and support staff can retry failed messages as a recovery action.

### Routes

| Path | Live session | Purpose |
|---|---|---|
| `/` | `:app` | Dashboard — channels grouped by org, throughput stats, cert expiry warnings |
| `/channels` | `:app` | Channel list; create/edit channels (includes org assignment) |
| `/channels/:id` | `:app` | Channel detail — transforms, destinations, TLS config, alerting, pause/resume |
| `/channels/:id/transforms/:id/editor` | `:app` | Full-screen transform script editor with live preview |
| `/channels/:id/messages` | `:app` | Message log — search by message type / patient ID, retry failed |
| `/messages/failed` | `:app` | Global dead letter queue — all failed messages across all channels |
| `/organizations` | `:app` | Organization list; create new organizations |
| `/organizations/:id` | `:app` | Organization detail — member channels, IP allowlist, alert config, TLS CA cert |
| `/users` | `:admin` | User list — admin management |
| `/tools/mllp-client` | `:admin` | Interactive MLLP client (plain TCP and TLS) for testing channels |
| `/tools/sinks` | `:admin` | View in-memory sink contents for testing destinations |
| `/tools/retention` | `:admin` | Message log retention settings and manual purge controls |
| `/audit` | `:admin` | Audit log — filterable history of admin mutations |
| `/users/settings` | `:app` | Account settings — email, password, API token management |
| `/api/docs` | (none) | Scalar — interactive OpenAPI documentation |

### Real-time updates

The dashboard and channel pages use Phoenix LiveView. Pipeline stats (processed count, error count, last message time) are broadcast over PubSub on `"channel:#{id}:stats"` and automatically push to connected browsers. The message log page subscribes to `"message_log:#{id}"` and streams new entries in real time.

---

## REST API

Joy exposes a `/api/v1` REST API for programmatic access to channels, organizations, destinations, the message log, and retention. It mirrors the LiveView UI's capabilities: the same context functions are called from both surfaces, with no separate business logic layer.

### Authentication

API requests are authenticated with **Bearer tokens** (`Authorization: Bearer <token>`). Joy has two token types, distinguished by prefix:

**User tokens** (`joy_` prefix):
- Created via the `/users/settings` page or `POST /api/v1/tokens` (email + password)
- Valid for 1–90 days (default 90); expired tokens are rejected automatically
- Capped at 10 active tokens per user; expired tokens are cleaned up on each new creation

**Service account tokens** (`joy_svc_` prefix):
- Created via `/service-accounts` (admin LiveView); one active token per service account
- No expiry — intended for Prometheus scrapers and CI pipelines; rotate manually via the UI
- Never carry admin privileges regardless of who created them

Both token types are shown in plaintext exactly once on creation — only the SHA-256 hash is stored.

`JoyWeb.Plugs.ApiAuth` branches on the prefix before hashing: `joy_svc_` tokens go to `Joy.ServiceAccounts.verify_token/1`, all others to `Joy.ApiTokens.verify_token/1`. Either path assigns `current_scope` and fires an async `Task.start` to update `last_used_at`.

### Authorization

`Joy.Accounts.Scope.admin?/1` controls access to mutations:

- **Read-only endpoints** (list/show channels, organizations, message log, metrics): open to any authenticated token (user or service account).
- **Mutations** (create/update/delete channels and orgs, lifecycle actions, destination changes, retention purge, message retry): require `Scope.admin?(scope)` to return true. This is true only for human users with `is_admin: true`. Service accounts always return false and receive 403.

### Routes

| Path | Methods | Purpose |
|---|---|---|
| `/api/v1/channels` | GET, POST | List channels; create channel |
| `/api/v1/channels/:id` | GET, PUT, DELETE | Get/update/delete a channel |
| `/api/v1/channels/:id/start` | POST | Start the channel's MLLP server |
| `/api/v1/channels/:id/stop` | POST | Stop the channel's MLLP server |
| `/api/v1/channels/:id/pause` | POST | Pause message dispatch |
| `/api/v1/channels/:id/resume` | POST | Resume message dispatch |
| `/api/v1/channels/:id/destinations` | GET, POST | List destinations; create destination |
| `/api/v1/channels/:id/destinations/:id` | PUT, DELETE | Update/delete a destination |
| `/api/v1/channels/:id/messages` | GET | List message log entries (filterable) |
| `/api/v1/channels/:id/messages/:id/retry` | POST | Retry a failed message (admin) |
| `/api/v1/organizations` | GET, POST | List orgs; create org |
| `/api/v1/organizations/:id` | GET, PUT, DELETE | Get/update/delete an org |
| `/api/v1/retention/purge` | POST | Trigger a synchronous retention purge (admin) |
| `/api/v1/metrics` | GET | Prometheus text format — per-channel throughput and running state |
| `/api/v1/tokens` | POST | Create a Bearer token (unauthenticated — accepts email + password) |
| `/api/v1/tokens/:id` | DELETE | Revoke one of the authenticated user's tokens |
| `/api/v1/openapi.json` | GET | OpenAPI 3.0 spec (unauthenticated) |
| `/api/docs` | GET | Scalar — interactive API documentation (unauthenticated) |
| `/service-accounts` | GET | Admin LiveView — manage service accounts and rotate tokens |

### OpenAPI / Scalar

`JoyWeb.API.ApiSpec` implements `OpenApiSpex.OpenApi` and builds the spec from the router using `OpenApiSpex.Paths.from_router/1`. All controllers are annotated with `use OpenApiSpex.ControllerSpecs` and declare `tags`, `security`, and per-action `operation` macros. The spec is served as JSON at `/api/v1/openapi.json` and rendered by **Scalar** (loaded from CDN) at `/api/docs`. Both are unauthenticated so integration teams can browse the API without credentials.

### Error format

`JoyWeb.FallbackController` normalizes errors:

| Condition | HTTP status | Body |
|---|---|---|
| `{:error, %Ecto.Changeset{}}` | 422 Unprocessable Entity | `%{errors: %{field: ["message"]}}` |
| `{:error, :not_found}` | 404 Not Found | `%{errors: %{detail: "Not found"}}` |
| `{:error, :unauthorized}` | 403 Forbidden | `%{errors: %{detail: "Admin access required"}}` |
| `{:error, :invalid_credentials}` | 401 Unauthorized | `%{errors: %{detail: "Invalid email or password"}}` |
| `{:error, :token_limit_reached}` | 422 Unprocessable Entity | `%{errors: %{detail: "Token limit reached (10 max)..."}}` |

### Sensitive field exclusions

Two fields are never included in API responses:

- `channels.tls_key_pem` — private key material
- `destination_configs.config` — may contain adapter credentials (API keys, passwords, connection strings)

---

## Service Accounts

Service accounts are named machine actors used for API access by non-human clients (Prometheus scrapers, CI pipelines, external integrations). They are managed separately from users — there is no email, no password, and no browser login.

Each service account has exactly one active token (`joy_svc_` prefix, no expiry). Rotating a token deletes the old row and inserts a new one atomically. The new token is shown once in the admin UI and never stored in plaintext.

Service accounts are **never admin**. `Joy.Accounts.Scope.admin?/1` returns `false` for any service account scope regardless of how it was created. They can read channels, organizations, message log, and metrics — but cannot mutate anything.

**Admin UI:** `/service-accounts` (LiveView, admin-only) — create, rotate token, delete.

**Auth flow:** `ApiAuth` detects the `joy_svc_` prefix, calls `Joy.ServiceAccounts.verify_token/1`, and assigns `%Scope{service_account: sa}`. The remainder of the request pipeline is identical to user token requests.

---

## Dispatch Concurrency

Each channel has a `dispatch_concurrency` setting (integer, default 1, max 20) that controls how many worker tasks the Pipeline runs simultaneously.

**concurrency = 1 (default):** The Pipeline spawns a task for each message but will not spawn the next until the current one sends `{:dispatch_done, ...}` back. Delivery order matches receive order. This is the right choice for any downstream system that requires strict sequencing. The Pipeline GenServer itself is never blocked — it processes incoming `cast` messages immediately and manages the task lifecycle through message passing.

**concurrency > 1:** Up to N tasks run simultaneously. Useful when a channel receives from many concurrent MLLP senders and has a slow destination (e.g. a high-latency HTTP webhook). Order is not guaranteed across concurrent senders. Within a single MLLP connection, the ACK-before-next protocol serializes sends at the sender, so per-connection ordering is always preserved regardless of this setting.

Messages that arrive while `in_flight >= concurrency` are buffered in a local FIFO queue in Pipeline state and dispatched as slots open. The GenServer mailbox acts as outer backpressure.

The setting is configurable per channel in the UI under the "Dispatch" section of the channel detail page. Changes take effect after saving (Pipeline reloads its channel config).

---

## Organizations

An **organization** groups a set of channels under a shared name — typically a health system or facility. Organizations are a UI and config grouping only; they do not affect message routing or processing.

**Shared config fallbacks:** An organization can carry an `allowed_ips` list, `alert_email`, `alert_webhook_url`, and `tls_ca_cert_pem`. These act as fallbacks:

- `Joy.Channels.effective_allowed_ips/1` returns the union of the channel's own `allowed_ips` and the organization's `allowed_ips`. `MLLP.Connection` uses this union for connection filtering.
- `Joy.Alerting.deliver/3` uses the channel-level `alert_email`/`alert_webhook_url` if set; otherwise falls back to the org's. If neither is set, no alert is delivered.

The `organization_id` FK on `channels` uses `on_delete: :nilify_all`. Deleting an organization orphans its channels back to ungrouped status — it does not delete channels. This is the correct behavior: organizations are metadata, not owners.

The same FK exists on `users` (also `nilify_all`) as a forward-compatible foundation for future org-scoped authentication. It is not currently enforced in access control.

**Dashboard grouping:** The dashboard uses `Enum.group_by(channels, & &1.organization)` to bucket channels by their preloaded org struct, then renders one `<tbody>` per org with an aggregate stat row. Channels with no org appear under an "Ungrouped" header. When all channels are ungrouped (no orgs exist), the table renders as a flat list identical to pre-org behavior.

---

## Message Log Retention

The `message_log_entries` table contains raw HL7 (PHI) and grows without bound. Retention manages this in two steps: **archive** then **delete**. Archiving is optional but deletion is not: the point is to remove old rows from the database.

**Archive backends:** Three backends implement `Joy.Retention.Archive`:

- `LocalFS` — writes gzip-compressed NDJSON to a directory on the server filesystem.
- `S3` — uploads to an S3 bucket with STANDARD storage class.
- `Glacier` — uploads to the same S3 bucket but with `x-amz-storage-class: GLACIER`, placing objects in Glacier retrieval tier (3–5 hour restore time). Uses the same S3 API and credentials as the S3 backend; no legacy Glacier Vault API.

All three receive the same gzip-compressed NDJSON payload. The archive format is one JSON object per line, one line per message log entry, including `raw_hl7`.

**Purge safety invariant:** `run_purge/1` archives first. If archiving fails, the function returns `{:error, reason}` and does not delete. Entries are only deleted after all archive chunks have been uploaded successfully. This means a partial failure leaves data in the database (safe) rather than deleting unarchived entries (unsafe).

**Chunking:** Entries are archived in chunks of 50,000 to bound memory usage. Each chunk becomes a separate timestamped file (`joy_archive_YYYYMMDD_HHMMSS_part1.ndjson.gz`, etc.). Deletion then proceeds in batches of 1,000 rows.

**Pending entries are never deleted.** The query always includes `AND status != 'pending'`. Pending entries are in-flight; deleting them would break at-least-once delivery.

**Scheduled purge:** `Joy.Retention.Scheduler` checks hourly whether to run. It fires if `schedule_enabled` is true, the current UTC hour matches `schedule_hour`, and `last_purge_at` is not already set to today. The `last_purge_at` guard provides coarse protection against duplicate runs in multi-node deployments — it is not a distributed lock, but the worst-case outcome (two nodes both archive the same entries on the same morning) is safe: entries are deleted once, and the archive gets two copies.

---

## Audit Logging

`Joy.AuditLog` is a context that records every admin-gated mutation as an immutable log entry. It provides traceability for HIPAA-relevant configuration changes — who changed what and when.

### Context API

- `Joy.AuditLog.log/6` — inserts one entry. Arguments: `actor_id`, `actor_email`, `action` (atom, e.g. `:created`, `:deleted`, `:started`), `resource_type` (string, e.g. `"channel"`), `resource_id`, `resource_name`, and a `changes` map.
- `Joy.AuditLog.list_entries/1` — queries entries with keyword opts: `resource_type:`, `actor_id:`, `from:`, `to:`, `limit:`.
- `Joy.AuditLog.purge_old/1` — deletes entries older than the given number of days. Called from the `/audit` page's manual purge button and (when configured) on a schedule.
- `Joy.AuditLog.count_total/0` and `count_purgeable/1` — counts for UI display.

### What is logged

Call sites exist at every admin-gated mutation: channel start/stop/pause/resume, TLS config, alert config, dispatch config, node pinning, IP allowlist add/remove, transform create/update/delete/toggle, destination create/update/delete/toggle, org create/update/delete, user promote/demote, and all dashboard lifecycle actions. The `changes` map contains only the fields that changed; for TLS saves it contains only boolean flags (`tls_enabled`, `cert_updated`, `key_updated`) — PEM content and destination credentials are never logged.

### `audit_log_entries` schema

```
actor_id      — nullable FK → users (nilify_all; email is denormalized so records survive user deletion)
actor_email   — denormalized email string
action        — string (e.g. "created", "deleted", "started", "stopped")
resource_type — string (e.g. "channel", "organization", "user")
resource_id   — integer (the resource's DB id)
resource_name — string (snapshot of the name at the time of the action)
changes       — jsonb (only changed fields; no secrets)
inserted_at   — immutable timestamp; no updated_at
```

Indexes on `actor_id`, `resource_type`, and `inserted_at` support the filter queries on the `/audit` LiveView.

### Retention

`retention_settings` carries an `audit_retention_days` integer column (default 365). The `/audit` admin page exposes a settings form for this window and a manual purge button that calls `Joy.AuditLog.purge_old/1`. Audit retention is managed separately from message log retention.

---

## Data Model

Ten tables, all in the `joy` Postgres database:

```
organizations
  id, name, slug (unique), description, inserted_at, updated_at
  allowed_ips (string[])        — unioned with per-channel list by effective_allowed_ips/1
  alert_email, alert_webhook_url — fallback for member channels with no individual alert config
  tls_ca_cert_pem (text)        — fallback CA cert for member channels with mTLS but no individual cert

channels
  id, name, description, mllp_port (unique), started, inserted_at, updated_at
  organization_id (FK → organizations, nilify_all)  — optional grouping; nil = ungrouped
  allowed_ips (string[])           — source IP allowlist; empty = allow all; see effective_allowed_ips/1
  paused (bool)                    — pipeline holds pending messages; MLLP server keeps accepting
  dispatch_concurrency (int)       — max simultaneous worker tasks; 1 = strict serial (default)
  tls_enabled (bool)
  tls_cert_pem (text)              — server certificate PEM (public)
  tls_key_pem (binary)             — private key PEM, encrypted at rest (Joy.Encrypted.StringType)
  tls_ca_cert_pem (text)           — CA cert for verifying client certs in mTLS (public)
  tls_cert_expires_at (utc_datetime) — parsed from cert at save time; queried by Joy.CertMonitor
  tls_verify_peer (bool)           — require client certificate (mutual TLS)
  alert_enabled (bool)
  alert_threshold (int)            — consecutive failures before alerting
  alert_email (string)
  alert_webhook_url (string)
  alert_cooldown_minutes (int)     — minimum minutes between alerts for the same channel
  ack_code_override (string)       — "AA", "AE", or "AR"; overrides success-path ACK code if set
  ack_sending_app (string)         — overrides MSH.3 in ACK responses; nil = mirror MSH.5 from inbound
  ack_sending_fac (string)         — overrides MSH.4 in ACK responses; nil = mirror MSH.6 from inbound
  pinned_node (string)             — Erlang node name to pin this channel to; nil = Horde placement

transform_steps
  id, channel_id (FK), name, script, enabled, position, inserted_at, updated_at

destination_configs
  id, channel_id (FK), name, adapter, config (encrypted binary),
  enabled, retry_attempts, retry_base_ms, inserted_at, updated_at

message_log_entries
  id, channel_id (FK), message_control_id, status (pending/processed/failed/retried),
  raw_hl7, transformed_hl7, error, processed_at, inserted_at
  message_type (varchar, indexed)  — MSH.9, extracted at persist time for search
  patient_id (varchar, indexed)    — PID.3, extracted at persist time for search
  UNIQUE INDEX (channel_id, message_control_id) WHERE message_control_id IS NOT NULL

users  (phx.gen.auth standard)
  id, email, hashed_password, is_admin, confirmed_at, inserted_at, updated_at
  organization_id (FK → organizations, nilify_all)  — foundation for future org-scoped auth; inert now

user_tokens  (phx.gen.auth standard)
  id, user_id (FK), token, context, sent_to, inserted_at

api_tokens
  id, user_id (FK → users, delete_all), name (string)
  token_hash (string, unique index)  — SHA-256 hex of the plain token; plain token is shown once and never stored
  expires_at (utc_datetime)          — defaults to 90 days; configurable at creation (1–90 days max); enforced in verify_token
  last_used_at (utc_datetime)        — updated asynchronously on each authenticated request
  inserted_at (utc_datetime)         — no updated_at; tokens are immutable after creation
  INDEX user_id
  Max 10 active tokens per user; expired tokens are deleted at create_token time before the limit is checked

service_accounts
  id, name (string), inserted_at
  Admin-managed machine actors; no email, no password, no login

service_account_tokens
  id, service_account_id (FK → service_accounts, delete_all)
  token_hash (string, unique index)  — SHA-256 hex; same hashing scheme as api_tokens
  last_used_at (utc_datetime)        — updated asynchronously on each authenticated request
  inserted_at (utc_datetime)
  UNIQUE INDEX service_account_id   — enforces one active token per service account
  No expiry; rotate manually via the /service-accounts admin UI

retention_settings  (single row — created on first access)
  id, retention_days (default 90), schedule_enabled, schedule_hour (UTC, default 2)
  archive_destination  — "none" | "local_fs" | "s3" | "glacier"
  local_path           — for local_fs backend
  aws_bucket, aws_prefix, aws_region
  aws_access_key_id (encrypted), aws_secret_access_key (encrypted)
  last_purge_at, last_purge_deleted, last_purge_archived
  audit_retention_days (int, default 365)  — audit log purge window; managed from /audit page
  inserted_at, updated_at

audit_log_entries  (append-only; no updated_at)
  id
  actor_id (FK → users, nilify_all)   — nil if user was deleted
  actor_email (text)                  — denormalized; survives user deletion
  action (string)                     — e.g. "created", "deleted", "started", "stopped"
  resource_type (string)              — e.g. "channel", "organization", "user"
  resource_id (integer)
  resource_name (string)              — snapshot at time of action
  changes (jsonb)                     — changed fields only; no secrets
  inserted_at
  INDEX actor_id, INDEX resource_type, INDEX inserted_at
```

`destination_configs.config` is an encrypted binary (map serialized as JSON then AES-256-GCM encrypted). The Ecto type (`Joy.Encrypted.MapType`) transparently encrypts on insert and decrypts on load using the `ENCRYPTION_KEY`. Adapters see a plaintext map.

`channels.tls_key_pem` and `retention_settings.aws_access_key_id` / `aws_secret_access_key` use the same encryption scheme via `Joy.Encrypted.StringType`, which encrypts/decrypts a raw string rather than a JSON map. Public-facing cert material and non-secret fields are stored as plain text.

`message_log_entries` contains raw HL7 (PHI) and grows over time. Configure a retention policy via `/tools/retention` appropriate to your compliance requirements (HIPAA minimum: 6 years for designated record sets; state law may differ).
