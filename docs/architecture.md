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
- [Data Model](#data-model)

---

## The Channel Model

A **channel** is the fundamental unit of work in Joy. Each channel represents a single intake point: it listens on a dedicated TCP port for incoming MLLP connections, applies a sequence of transform scripts, and delivers the result to one or more destinations.

Channels are independent. A crash in channel A — its transform script, its MLLP server, its destinations — cannot affect channel B. This isolation is enforced structurally at the process level, not by convention.

At runtime, each channel is an isolated OTP supervisor tree containing exactly two processes:

- **Pipeline** — the processing brain. Holds the channel's config (transforms, destinations) in memory. Receives messages and processes them one at a time. Supports pause/resume: when paused, new dispatches are held in the DB as `:pending` and the MLLP server keeps accepting.
- **MLLP.Server** — the TCP listener. Accepts plain TCP or TLS connections (per channel config), hands each to a short-lived Connection process, and sends ACKs.

Both run under a per-channel `:rest_for_one` supervisor. If the Pipeline crashes, both the Pipeline and MLLP.Server restart together (the Server needs a live Pipeline to dispatch to). If only the Server crashes, only the Server restarts — the Pipeline's state (counters, cached config) is preserved.

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

Step 5 is asynchronous (`GenServer.cast`): the Connection does not wait for processing to complete before handling the next message. The Pipeline processes one message at a time (its mailbox is the queue), which naturally serializes processing per channel. This matches MLLP's flow-control model: upstream senders wait for an ACK before sending the next message, so serialization at the channel level is correct behavior.

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
│                                    {:mllp_server, channel_id} → MLLP.Server PID
│
├── Joy.TransformSupervisor    Task.Supervisor — sandboxed script execution (node-local)
├── Joy.ChannelStats           GenServer — ETS-backed per-channel throughput counters (node-local)
├── Joy.Alerting               GenServer — ETS-backed consecutive failure tracking + alert delivery (node-local)
├── Joy.CertMonitor            GenServer — daily TLS cert expiry check; fires alerts via Joy.Alerting (node-local)
├── Joy.Sinks                  GenServer — in-memory test sink (node-local)
│
├── Joy.MLLP.ConnectionSupervisor   DynamicSupervisor (:one_for_one, node-local)
│   ├── Joy.MLLP.Connection    per active TCP connection (:temporary — not restarted)
│   └── ...
│
├── Joy.ChannelSupervisor      Horde.DynamicSupervisor — distributed channel trees
│   │
│   ├── Joy.Channel.Supervisor  [channel 1]  (:rest_for_one)
│   │   ├── [0] Joy.Channel.Pipeline         GenServer — processes messages
│   │   └── [1] Joy.MLLP.Server              GenServer — TCP listener on mllp_port
│   │
│   ├── Joy.Channel.Supervisor  [channel 2]  (:rest_for_one)
│   │   ├── [0] Joy.Channel.Pipeline
│   │   └── [1] Joy.MLLP.Server
│   │
│   └── ...  (one tree per started channel, distributed across cluster nodes)
│
├── Joy.ChannelManager         GenServer — lifecycle control plane
└── JoyWeb.Endpoint            Phoenix HTTP/WebSocket endpoint
```

**Why `:one_for_one` at the top?** Each child serves a completely different function. A crashed Repo should not restart the PubSub; a crashed Endpoint should not restart ChannelManager. Every child is independent.

**Why `:rest_for_one` per channel?** The Pipeline must be alive before the MLLP.Server can dispatch messages to it. If the Pipeline crashes, the Server is also restarted so it connects to the fresh Pipeline. If only the Server crashes (e.g., port conflict on restart), the Pipeline's in-memory stats and cached config are preserved.

**Why is `ConnectionSupervisor` node-local while `ChannelSupervisor` is distributed?** TCP connections are inherently tied to the machine that accepted them. When a connection closes or the node dies, the connection process is gone regardless. There is nothing to distribute. Channel supervisor trees, by contrast, represent persistent channel state that should survive node failures — that is exactly what Horde provides.

**`ChannelManager`** is not the supervisor — it is a GenServer that provides the `start_channel/1`, `stop_channel/1`, `pause_channel/1`, and `resume_channel/1` API. On startup it reads `started: true` channels from the database and starts their OTP trees via `Horde.DynamicSupervisor`. The ChannelManager runs on every node; Horde deduplicates.

**`ChannelStats` and `Alerting`** are node-local GenServers backed by ETS. `ChannelStats` tracks received/processed/failed counts per channel per day; `Alerting` tracks consecutive failures and fires email/webhook alerts when a per-channel threshold is exceeded. Both are intentionally node-local: they track ephemeral runtime state that resets on restart, not durable data.

**`CertMonitor`** is a node-local GenServer that runs a TLS certificate expiry check on startup and every 24 hours. It queries channels whose `tls_cert_expires_at` is within 30 days and calls `Joy.Alerting.send_direct/3` to fire an email/webhook alert. Because it reads from the database, it works correctly regardless of which node is running each channel.

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

All web routes require authentication and admin status. Users can self-register, but freshly registered users cannot access anything until promoted to admin via `mix joy.make_admin`. This is intentional: Joy manages healthcare infrastructure and should not be accessible to arbitrary authenticated users.

Authentication uses `phx.gen.auth` (email + password + magic link via email token). Session tokens are stored in the database (`user_tokens` table), so sessions work correctly across a cluster without sticky sessions or shared cookie signing concerns.

### Routes

| Path | Purpose |
|---|---|
| `/` | Dashboard — channel status, throughput stats, cert expiry warnings |
| `/channels` | Channel list; create new channels |
| `/channels/:id` | Channel detail — transforms, destinations, TLS config, alerting, pause/resume |
| `/channels/:id/transforms/:id/editor` | Full-screen transform script editor with live preview |
| `/channels/:id/messages` | Message log — search by message type / patient ID, retry failed |
| `/messages/failed` | Global dead letter queue — all failed messages across all channels |
| `/users` | User list — admin management |
| `/tools/mllp-client` | Interactive MLLP client (plain TCP and TLS) for testing channels |
| `/tools/sinks` | View in-memory sink contents for testing destinations |

### Real-time updates

The dashboard and channel pages use Phoenix LiveView. Pipeline stats (processed count, error count, last message time) are broadcast over PubSub on `"channel:#{id}:stats"` and automatically push to connected browsers. The message log page subscribes to `"message_log:#{id}"` and streams new entries in real time.

---

## Data Model

Five tables, all in the `joy` Postgres database:

```
channels
  id, name, description, mllp_port (unique), started, inserted_at, updated_at
  allowed_ips (string[])           — source IP allowlist; empty = allow all
  paused (bool)                    — pipeline holds pending messages; MLLP server keeps accepting
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

transform_steps
  id, channel_id (FK), name, script, enabled, position, inserted_at, updated_at

destination_configs
  id, channel_id (FK), name, adapter, config (encrypted binary),
  enabled, retry_attempts, retry_base_ms, inserted_at, updated_at

message_log_entries
  id, channel_id (FK), message_control_id, status (pending/processed/failed/retried),
  raw_hl7, transformed_hl7, error, processed_at, inserted_at, updated_at
  message_type (varchar, indexed)  — MSH.9, extracted at persist time for search
  patient_id (varchar, indexed)    — PID.3, extracted at persist time for search
  UNIQUE INDEX (channel_id, message_control_id) WHERE message_control_id IS NOT NULL

users  (phx.gen.auth standard)
  id, email, hashed_password, is_admin, confirmed_at, inserted_at, updated_at

user_tokens  (phx.gen.auth standard)
  id, user_id (FK), token, context, sent_to, inserted_at
```

`destination_configs.config` is an encrypted binary (map serialized as JSON then AES-256-GCM encrypted). The Ecto type (`Joy.Encrypted.MapType`) transparently encrypts on insert and decrypts on load using the `ENCRYPTION_KEY`. Adapters see a plaintext map.

`channels.tls_key_pem` uses the same encryption scheme via `Joy.Encrypted.StringType`, which encrypts/decrypts the raw PEM string rather than a JSON map. The server cert and CA cert are public data and stored as plain text.

`message_log_entries` is the only table that grows unboundedly. It contains raw HL7 (PHI). Plan a retention policy appropriate to your compliance requirements.
