# Design Notes

This document covers specific implementation decisions in Joy: why something was built a particular way, what alternatives were considered, and where the edges and known limitations are. It is intended for contributors or anyone debugging a subtle failure.

## Contents

- [MLLP Framing and Leniency](#mllp-framing-and-leniency)
- [TCP Connection Model](#tcp-connection-model)
- [MLLP TLS: Transport Abstraction](#mllp-tls-transport-abstraction)
- [Pipeline Serialization](#pipeline-serialization)
- [Channel Pause/Resume](#channel-pauseresume)
- [At-Least-Once Delivery: Full Details](#at-least-once-delivery-full-details)
- [Registry Key Design](#registry-key-design)
- [ChannelManager vs ChannelSupervisor](#channelmanager-vs-channelsupervisor)
- [Channel Supervisor Child Spec](#channel-supervisor-child-spec)
- [Transform Validator: Threat Model](#transform-validator-threat-model)
- [Transform Runner: Isolation Details](#transform-runner-isolation-details)
- [HL7 Parser Leniency](#hl7-parser-leniency)
- [HL7 Accessor: Indexing and Padding](#hl7-accessor-indexing-and-padding)
- [Encryption: AES-256-GCM Details](#encryption-aes-256-gcm-details)
- [Encrypted Ecto Type](#encrypted-ecto-type)
- [Retry: Backoff Formula and Placement](#retry-backoff-formula-and-placement)
- [Horde: Deduplication and Startup Race](#horde-deduplication-and-startup-race)
- [ChannelStats: ETS Design](#channelstats-ets-design)
- [Alerting: Consecutive Failure Detection](#alerting-consecutive-failure-detection)
- [Message Search: Extract at Persist Time](#message-search-extract-at-persist-time)
- [Sinks: Design as a Test Tool](#sinks-design-as-a-test-tool)
- [Known Gaps](#known-gaps)

---

## MLLP Framing and Leniency

### Frame format

MLLP wraps each HL7 message with three bytes:

```
0x0B  <HL7 message bytes>  0x1C 0x0D
 VT        content          FS   CR
```

`Joy.MLLP.Framer` uses Elixir binary pattern matching to detect and strip these bytes. The start byte is matched structurally (`<<0x0B, rest::binary>>`), and `:binary.match/2` locates the end marker in the remainder. This is more efficient than scanning byte-by-byte and avoids constructing intermediate strings.

### Leniency for missing start byte

`Framer.unwrap/1` has a second clause that accepts messages beginning with `MSH` and no `0x0B`:

```elixir
def unwrap(<<"MSH", _::binary>> = data) do ...
```

This exists because some older HL7 senders (and some test harnesses) omit the start byte. A strict parser would reject these silently, which in a healthcare environment could mean messages are lost with no indication of why. The lenient approach accepts them, which is safer. The parser (`Joy.HL7.Parser`) has the same leniency — it strips MLLP bytes if present and otherwise proceeds.

### Buffer management

Each `Joy.MLLP.Connection` maintains a `buffer` string in its state. Incoming TCP data is appended to this buffer, then `process_buffer/1` attempts to extract complete frames in a loop. This handles TCP fragmentation (a single HL7 message arriving as multiple TCP segments) and TCP coalescing (multiple HL7 messages arriving in a single TCP segment). The loop calls `Framer.unwrap` until it gets `:incomplete` (need more data) or `{:error, :invalid_frame}`.

On `:invalid_frame`, the entire buffer is discarded and a warning is logged. This is a hard choice: discarding might mean losing a partial message, but an unrecognizable buffer has no safe recovery path. The upstream sender will not receive an ACK and will retry.

### ACK field separator preservation

`Framer.build_ack/2` reads the field separator and encoding characters (`comp_sep`, `rep_sep`, etc.) from the incoming message's MSH header and uses the same characters in the ACK response. This matters: some legacy systems validate that the ACK uses the exact same separators they sent, and will reject a response with different ones. Building the ACK from the original MSH also correctly swaps sender and receiver fields (MSH.3/4 ↔ MSH.5/6), which is required by the HL7 standard.

---

## TCP Connection Model

### Why connections are not inside the channel OTP tree

`Joy.MLLP.ConnectionSupervisor` is a global `DynamicSupervisor` at the top level of the application, not inside each channel's per-channel supervisor. This is intentional:

- Connection crashes do not cascade to the channel supervisor. If a connection GenServer crashes (malformed data, client misbehavior, etc.), the channel keeps running.
- The ConnectionSupervisor does not need to be distributed via Horde. TCP connections are inherently local to the machine that accepted them — there is nothing meaningful to migrate when a connection process dies. When a node fails, the OS closes its TCP sockets and the sender reconnects.

### `:temporary` restart strategy

`MLLP.Connection` has `restart: :temporary`. OTP will not restart it after a crash. This is correct: a reconnected client starts a new connection process; restarting an old connection process that already had a closed socket would just fail again. There is no state worth preserving in a connection process — the at-least-once guarantee lives in the database, not in the connection.

### Active mode TCP

The connection uses `:inet.setopts(socket, active: true)`, which means TCP data arrives as `{:tcp, socket, data}` messages to the GenServer's mailbox. The alternative (`active: false`) would require the process to explicitly call `recv` in a separate loop. Active mode is simpler, integrates naturally with GenServer message handling, and benefits from OTP's back-pressure: the GenServer mailbox provides natural buffering and the scheduler controls when messages are processed.

---

## MLLP TLS: Transport Abstraction

### Why not Ranch or a TLS proxy?

The ROADMAP mentioned Ranch as a possible approach. Ranch was not used because the existing MLLP server already used raw `:gen_tcp` directly, and introducing Ranch would have required restructuring the accept loop substantially. Instead, TLS is layered in by carrying a **transport atom** (`:gen_tcp` or `:ssl`) through the server/connection boundary and dispatching all socket operations through it.

### The transport atom pattern

`Joy.MLLP.Server` checks `channel.tls_enabled` in `init/1` and calls either `:gen_tcp.listen/2` or `:ssl.listen/2`. For TLS, the accept loop has two phases:

```elixir
{:ok, socket} = :ssl.transport_accept(listen_socket)  # wait for TCP connection
{:ok, tls_socket} = :ssl.handshake(socket)             # upgrade to TLS
```

The transport atom and the live socket are passed together to `Joy.MLLP.Connection.start_link/1`. The Connection carries the transport in its state and uses it for every socket operation:

```elixir
# set active mode
:gen_tcp.setopts(socket, active: true)   # plain TCP
:ssl.setopts(socket, active: true)       # TLS

# send
:gen_tcp.send(socket, data)
:ssl.send(socket, data)
```

Active-mode messages differ by transport — `:tcp` tuple vs `:ssl` tuple — so the Connection has separate `handle_info` clauses for each.

### PEM stored in DB, not file paths

Cert material is stored as PEM text in the database rather than as filesystem paths. This makes the deployment story simpler — no volume mounts in Docker, no cert files to manage on the server, no breakage when a container is replaced.

The private key is stored via `Joy.Encrypted.StringType`, an Ecto type that encrypts/decrypts the raw PEM string using the same AES-256-GCM scheme as destination credentials. The server cert and CA cert are public data and stored as plain text.

`listen_opts/1` decodes PEM to DER at channel start time using `:public_key.pem_decode/1`:

```elixir
[{:Certificate, cert_der, _} | _] = :public_key.pem_decode(channel.tls_cert_pem)
[{key_type, key_der, _} | _] = :public_key.pem_decode(channel.tls_key_pem)
# :ssl accepts :cert (DER binary) and :key ({type, DER binary})
opts = [cert: cert_der, key: {key_type, key_der}, ...]
```

`key_type` is whatever the PEM header says — `:RSAPrivateKey`, `:ECPrivateKey`, or `:PrivateKeyInfo` (PKCS#8) — and `:ssl` accepts all three. This means RSA, ECDSA, and PKCS#8-wrapped keys all work without special handling.

### Restarting the channel on TLS config change

TLS options are baked into the listening socket at `listen/2` time. Changing cert paths or toggling `tls_enabled` while a channel is running would have no effect on the existing socket. The `save_tls` event in `ShowLive` therefore restarts the channel (stop + start) immediately after updating the DB record, so the new TLS config takes effect.

---

## Pipeline Serialization

Each channel's Pipeline GenServer processes one message at a time, sequentially. This is a deliberate match with MLLP's own flow control: MLLP senders wait for an ACK before sending the next message. A sender on a single connection is already serialized at the protocol level. Multiple concurrent connections to the same channel each get their own Connection process, but all dispatch to the same Pipeline via `GenServer.cast`. The Pipeline mailbox queues these and processes them in arrival order.

**Why not a pool of Pipeline workers?** The gains would be marginal. Each channel's MLLP port accepts connections from upstream systems that themselves serialize sends. Parallelism within a channel would primarily help when a destination is slow (e.g., an HTTP webhook timing out), but destinations run synchronously in the Pipeline — a slow destination blocks the Pipeline. This is another known gap: see [Known Gaps](#known-gaps).

The pipeline re-fetches each message entry from the database by ID (`Joy.MessageLog.get_entry!/1`) rather than using the original message struct dispatched by the Connection. This ensures correctness during crash recovery: the requeued messages on startup also go through the same fetch path.

---

## Channel Pause/Resume

### Design goal

Pausing a channel should stop message *processing* without stopping message *ingestion*. Upstream systems keep sending; messages are persisted and ACK'd as normal; nothing is lost. The pipeline just doesn't forward them to destinations until resumed.

### Implementation

`paused` is a boolean on the `channels` table. The Pipeline GenServer carries a `paused` field in its state. When paused:

- `handle_cast({:process, _entry_id}, %{paused: true} = state)` — returns `{:noreply, state}` immediately without processing. The entry stays `:pending` in the database.
- `handle_cast({:set_paused, true}, state)` — sets `paused: true` and logs.
- The MLLP.Connection is entirely unaffected — it continues accepting connections, persisting messages, and sending ACKs.

On resume:

- `handle_cast({:set_paused, false}, state)` — sets `paused: false`, then calls `Joy.MessageLog.list_pending(channel_id)` to enumerate all `:pending` entries accumulated while paused, and dispatches each via `process_async/1`. This is the same code path used during startup recovery.

### Why not stop the Pipeline GenServer?

Stopping the Pipeline would require coordinating across the `ChannelSupervisor` tree and would prevent restarting it cleanly. The cast no-op approach is simpler: it adds a single guard clause to the pipeline's hot path and uses the existing startup requeue logic for recovery. No new code paths — just a boolean check.

---

## At-Least-Once Delivery: Full Details

### The upsert

`MessageLog.persist_pending/3` uses `Repo.insert` with `on_conflict: :nothing`:

```elixir
Repo.insert(changeset,
  on_conflict: :nothing,
  conflict_target: {:unsafe_fragment, "(channel_id, message_control_id) WHERE message_control_id IS NOT NULL"},
  returning: true
)
```

The `conflict_target` is a partial index expression matching the database index:

```sql
UNIQUE INDEX (channel_id, message_control_id)
WHERE message_control_id IS NOT NULL
```

The `WHERE message_control_id IS NOT NULL` makes this a **partial unique index**: it only enforces uniqueness for messages that have a control ID. Messages without one (which happens with some malformed senders) are never deduplicated — each gets a new row. This is the safe choice: silently dropping a message because it lacks a control ID would be worse than processing a duplicate.

### The `%{id: nil}` sentinel

When `on_conflict: :nothing` fires, Postgres returns no rows. Ecto's `returning: true` then returns a struct with all fields set to `nil`. The Connection pattern-matches on this:

```elixir
case Joy.MessageLog.persist_pending(...) do
  {:ok, %{id: nil}} ->  # duplicate — ACK and skip
  {:ok, entry}     ->  # new — ACK and dispatch
  {:error, ...}    ->  # DB error — send AE ACK
end
```

The `id: nil` sentinel is a reliable signal because auto-generated IDs are always positive integers. This pattern avoids needing a separate existence check before insert.

### Crash scenarios

| Crash point | What happens |
|---|---|
| Before `persist_pending` | No ACK sent. Sender retries. Nothing was written. |
| After `persist_pending`, before ACK | Sender retries (no ACK = retry). Second attempt hits `on_conflict: :nothing`, gets `id: nil`, sends ACK, does not dispatch again. The original `:pending` entry is requeued by Pipeline on restart. |
| After ACK, before `cast` to Pipeline | Pipeline requeues on next start via `list_pending`. |
| During processing, before `mark_processed` | Entry remains `:pending`. Pipeline requeues on next start. |
| After `mark_processed` | Entry is `:processed`. Not requeued. |

The one failure mode this does **not** protect against is a database failure between parsing and persisting — if the DB is unreachable, the Connection sends `AE` and the sender must retry. At-least-once delivery requires the database to be available to accept the initial write.

---

## Registry Key Design

`Joy.ChannelRegistry` is a single `Horde.Registry` that stores three kinds of entries, distinguished by key type:

| Key | Value | Used by |
|---|---|---|
| `channel_id` (integer) | Channel.Supervisor PID | ChannelManager stop/running-check |
| `{:pipeline, channel_id}` | Pipeline PID | Pipeline.process_async, get_stats, reload_config |
| `{:mllp_server, channel_id}` | MLLP.Server PID | (reserved; not currently used for lookup) |

The original code declared a separate `Joy.PipelineRegistry` but never used it — Pipeline registered in `Joy.ChannelRegistry` with the tuple key. The dead `PipelineRegistry` was removed in the Horde migration.

**Why one registry for everything?** Fewer processes in the supervision tree, simpler reasoning about what's running. The tuple key space is easy to extend if future process types need to be found by channel ID.

**Why does MLLP.Server register itself at all?** The registration is not currently used for lookup — ChannelManager finds the channel supervisor (not the server) when stopping a channel. The server registers itself as a convenience for potential future tooling (e.g., the MllpClientLive could list active server PIDs) and for visibility in `:observer`.

---

## ChannelManager vs ChannelSupervisor

These two names are easy to confuse. The distinction is:

- **`Joy.ChannelSupervisor`** (`Horde.DynamicSupervisor`): the OTP supervisor that *owns* the per-channel trees. It restarts crashed channels per OTP rules. It has no application-level knowledge.
- **`Joy.ChannelManager`** (GenServer): the *control plane* that talks to the supervisor. It knows about the database, loads `started: true` channels on boot, and exposes `start_channel/1` / `stop_channel/1` to the rest of the app.

This separation is why the ChannelManager exists at all — `DynamicSupervisor` only accepts supervision-related messages. Putting business logic (DB queries, PubSub broadcasts) into a supervisor callback would be wrong. The GenServer acts as the policy layer; the supervisor is the mechanism layer.

---

## Channel Supervisor Child Spec

`Joy.Channel.Supervisor` defines a custom `child_spec/1`:

```elixir
def child_spec(%Joy.Channels.Channel{id: id} = channel) do
  %{
    id: {__MODULE__, id},
    start: {__MODULE__, :start_link, [channel]},
    type: :supervisor,
    restart: :permanent
  }
end
```

Three things here matter for Horde:

**`id: {__MODULE__, id}`** — the child spec ID must be globally unique across the cluster for Horde to deduplicate correctly. Using `{Joy.Channel.Supervisor, 5}` for channel 5 ensures no two nodes ever both run channel 5's tree simultaneously.

**`type: :supervisor`** — OTP uses this to determine shutdown behavior. Supervisors receive `{:shutdown, :infinity}` on termination, giving them time to cleanly shut down their children. Workers default to 5 seconds. Omitting this causes subtle shutdown ordering bugs.

**`restart: :permanent`** — if the channel supervisor tree crashes (as opposed to being intentionally stopped), Horde will restart it. This is the HA guarantee: a crash in the Pipeline or MLLP.Server propagates up through the per-channel supervisor, and Horde restarts the whole tree on any surviving node.

---

## Transform Validator: Threat Model

The validator's threat model is documented in the module: **semi-technical users in a healthcare environment**. This is not adversarial-strength sandboxing against a motivated attacker with full Elixir knowledge. It is protection against:

- Accidental dangerous calls (someone types `System.cmd("rm", ["-rf", "/"])` not knowing what it does)
- Copy-paste mistakes that include dangerous code
- Curious exploration of what the scripting environment can do

The AST whitelist approach is correct for this threat model: it fails closed (unknown nodes are not rejected, but blocked module calls are). The blocked list covers the realistic surface area: `File`, `System`, `Process`, `Node`, `Port`, `IO`, all Erlang atom-module calls, and meta-programming primitives.

**What it does not block:** a determined attacker who knows Elixir could potentially find a whitelisted function that indirectly triggers a side effect. The `Task.Supervisor` timeout (5 seconds) limits DoS via infinite loops. For stronger sandboxing, a separate OS process with seccomp filtering would be needed — that is out of scope for the current design.

**The `persistent_term` cache** stores validation results keyed by SHA-256 hash of the script. `persistent_term` is designed for rarely-written, frequently-read global data — it is faster than ETS for reads because the data lives in a read-only memory area accessible without copying. Validation is pure (same script always produces the same result), so caching is correct. The cache is per-node and is cleared on node restart.

---

## Transform Runner: Isolation Details

### `async_nolink` vs `async`

`Task.Supervisor.async_nolink/2` is used instead of `async/2`. The difference: `async` links the calling process to the task, so if the task crashes, the caller crashes too. `async_nolink` does not link them — the task can exit without affecting the Pipeline GenServer.

The follow-up is `Task.yield/2` instead of `Task.await/2`. `yield` returns `nil` on timeout rather than raising, giving a clean path to handle the timeout case and call `Task.shutdown/1` to clean up the task.

### The import prepend

```elixir
wrapped = "import Joy.Transform.DSL\n" <> script
```

DSL functions are injected by prepending `import Joy.Transform.DSL` to the script, making them available without requiring the user to write `import` themselves. This is why line numbers in error messages are decremented by 1 in `format_diagnostics` — the user's line 1 is line 2 in the wrapped script.

### `Code.with_diagnostics`

Elixir's `Code.eval_string` on a script with compile errors raises a generic `CompileError` with the message `"cannot compile file (errors have been logged)"`. The actual error details are emitted to the logger, not returned. `Code.with_diagnostics/1` captures those diagnostics as structured data before they disappear into the logger, allowing `format_diagnostics/1` to return them as a readable error message to the user. This is the only way to show the user which line had a syntax error.

---

## HL7 Parser Leniency

The parser's design philosophy is stated in its moduledoc: **a strict parser that crashes on minor deviations is a patient safety risk**. Real-world HL7 includes:

- Missing MLLP framing bytes (some senders omit `0x0B`)
- Mixed line endings (`\r\n`, `\r`, `\n` — HL7 uses `\r` but senders vary)
- Nonstandard encoding characters (rare but real)
- Trailing whitespace or garbage after the last segment

The parser handles all of these silently. Delimiter extraction uses a binary pattern match against `"MSH"` followed by the field separator and four encoding characters; if the message doesn't look like valid MSH, it falls back to standard defaults (`|`, `^`, `~`, `\`, `&`).

The one thing the parser does not handle gracefully is a genuinely empty message — it returns `{:error, "Empty message"}`. The Connection handles this by sending an `AE` ACK.

---

## HL7 Accessor: Indexing and Padding

### The indexing mismatch

HL7 field numbering is **1-based** (field 1 is the first data field after the segment name). Internally, segments are stored as lists where index 0 is the segment name itself (`["PID", "", "12345", ...]`). The accessor translates 1-based HL7 field numbers to 0-based list indices by using the field number directly as the list index — because the segment name at position 0 occupies the slot that would be "field 0", field 1 is at list index 1. This is the correct and intuitive mapping.

Component access (`"PID.5.1"`) is 1-based per HL7 convention. The accessor subtracts 1 before calling `Enum.at`. A component index of `nil` means "the whole field" (no component specified), returning the raw field string unsplit.

### Segment occurrence indexing

Paths like `"OBX[2].5"` use **1-based** occurrence indexing (first OBX is `OBX[1]` or just `OBX`). Internally, `parse_seg_part` converts this to 0-based before calling `find_segment`. So `OBX[2]` maps to the segment at occurrence index 1.

### Padding on set

When writing to a path that requires more fields than the segment currently has, `update_field` calls `pad_list` to extend the field list with empty strings:

```elixir
padded = pad_list(fields, field_idx + 1, "")
```

This ensures that setting `PID.20` on a message where PID only has 10 fields produces valid (if sparse) HL7 rather than crashing. The same logic applies to component access within a field.

When `set` targets a segment that doesn't exist, `find_or_create_segment` returns `{:new, %{name: name, fields: [name]}}` — a minimal segment with just its name. The new segment is appended to the end of the segment list. This is not sophisticated (it ignores HL7 segment ordering rules), but it handles the common case of creating a new Z-segment.

---

## Encryption: AES-256-GCM Details

### Wire format

`Joy.Crypto` stores encrypted values as a single binary:

```
<<IV::12-bytes, TAG::16-bytes, CIPHERTEXT::variable>>
```

The IV (initialization vector, also called nonce in GCM) is 12 bytes, which is the recommended size for GCM and is required for the counter-based construction to work correctly. A fresh 12-byte IV is generated with `:crypto.strong_rand_bytes(12)` for every encryption call — IVs must never be reused with the same key.

The TAG is the 16-byte GCM authentication tag. It authenticates both the ciphertext and the Additional Authenticated Data (AAD). Any bit flip in the ciphertext or the AAD during transit or storage is detected on decryption — `:crypto.crypto_one_time_aead` returns an error rather than silently returning corrupted plaintext.

### Additional Authenticated Data (AAD)

The AAD is the constant string `"joy_hl7_engine_v1"`. It is not encrypted (it is not part of the ciphertext), but any attempt to decrypt with a different AAD will fail authentication. Its purpose is **domain separation**: a ciphertext produced by Joy cannot be decrypted by a different system that happens to use the same key but a different AAD. This guards against ciphertext being copied between applications or schema versions misusing each other's blobs. The `v1` suffix leaves room for a future `v2` scheme without ambiguity.

### Key derivation

The key is read from `Application.fetch_env!(:joy, :encryption_key)` and Base64-decoded. The caller is responsible for generating a 32-byte key. There is no KDF (key derivation function) — the environment variable IS the key. This means key quality is entirely up to the operator. The generation instructions (`iex -e ":crypto.strong_rand_bytes(32) |> Base.encode64()"`) produce a cryptographically random 32-byte key, which is correct.

**No key rotation is implemented.** All records in the database are encrypted with the same key. Rotating the key would require re-encrypting every `destination_configs.config` value. This is a known gap.

---

## Encrypted Ecto Type

`Joy.Encrypted.MapType` implements `Ecto.Type` with four callbacks:

- **`type/0`** returns `:binary` — the database stores the encrypted blob as a raw binary column (PostgreSQL `bytea`).
- **`cast/1`** accepts maps and keyword lists; called when user input is assigned to a changeset. No encryption here — cast just validates shape.
- **`dump/1`** is called when writing to the database. `map → JSON → encrypt → binary`.
- **`load/1`** is called when reading from the database. `binary → decrypt → JSON → map`.

The key thing: **encryption and decryption happen at the Ecto boundary**. Adapters and the rest of the application see plaintext maps. The only place the raw binary appears is in database queries and migration files.

If `load` is called with a blob encrypted under a different key (wrong `ENCRYPTION_KEY`), `Joy.Crypto.decrypt` returns `{:error, :decryption_failed}` and `load` returns `:error`. Ecto will raise on `:error` from `load`. This means a key mismatch causes the channel to fail to load its destination config on startup, which is immediately visible. It is a hard failure rather than a silent corruption.

---

## Retry: Backoff Formula and Placement

### The formula

```elixir
exp = trunc(base_ms * :math.pow(2, attempt))
jitter = :rand.uniform(base_ms)
min(exp + jitter, @max_sleep_ms)
```

For `base_ms = 1000` and successive attempts:
- Attempt 0: ~1000ms ± rand(1000)
- Attempt 1: ~2000ms ± rand(1000)
- Attempt 2: ~4000ms ± rand(1000)
- Capped at 30 seconds

The **jitter** is the important part. Without it, if 20 channels all start retrying simultaneously (e.g., after a shared HTTP destination goes down), they all retry at the same time when it recovers and hammer it again. Adding `rand(0..base_ms)` spreads retries across a base_ms-wide window, smoothing the retry load.

### Placement: synchronous in the Pipeline

Retries block the Pipeline GenServer. This means a slow or unreachable destination can block message processing for a channel for up to `retry_attempts × max_sleep_ms` seconds. For a channel configured with 3 attempts and 1s base delay, the worst case is ~7 seconds of blocking per message.

This is intentional for the typical use case: a destination being briefly unavailable should slow down, not drop messages. The single-channel isolation ensures one channel's stuck destination does not affect other channels.

For channels where destination latency is critical, keep `retry_attempts` low and handle retries at the destination layer (e.g., SQS provides its own retry/DLQ). This is a design trade-off worth being aware of.

---

## Horde: Deduplication and Startup Race

### How deduplication works

`Horde.DynamicSupervisor` tracks running children by their `child_spec.id`. If `start_child/2` is called with a spec whose ID is already registered in the cluster, it returns `{:error, {:already_started, pid}}`. Joy's `ChannelManager.do_start_channel/1` handles this as a non-error:

```elixir
{:error, {:already_started, _pid}} ->
  # Another node in the cluster already started this channel
  :ok
```

This is what allows every node's ChannelManager to independently call `start_channel` for all `started: true` channels on boot without causing duplicate channels to run.

### The startup race

There is a brief window during cluster boot where two nodes can both attempt `start_child` for the same channel ID simultaneously before either's call has replicated through Horde's CRDT. In the worst case, both calls succeed and two instances start, but Horde's conflict resolution (based on the distributed registry) will terminate one of them within milliseconds. The surviving one will be the one whose registration "won" in the CRDT merge. The losing instance is stopped by Horde, not by the application — from the application's perspective, the channel ends up running exactly once.

This race is inherent to any eventually-consistent distributed supervisor. The window is small and the resolution is automatic. No messages are lost during this window because the at-least-once guarantee lives in the database.

### `members: :auto`

Both `Horde.Registry` and `Horde.DynamicSupervisor` are started with `members: :auto`. This tells Horde to use its built-in `Horde.NodeListener`, which subscribes to Erlang's `:nodeup` and `:nodedown` events and automatically adds/removes Horde cluster members as Erlang nodes connect and disconnect. No explicit member management is needed; `dns_cluster` handles the Erlang node connections and Horde handles the rest.

---

## ChannelStats: ETS Design

### Why ETS instead of DB counters?

Each inbound message increments at least one counter (received). Each processed message increments two (processed or failed). At any meaningful throughput these are very frequent writes. Incrementing DB rows for every message would create heavy write contention on the `channels` table. ETS provides lock-free atomic counter operations (`update_counter/3`) with microsecond latency.

The trade-off: ETS is node-local and lost on restart. The stats are labeled "Today" throughout the UI — transient, operational visibility, not audit records. The message log is the audit record. Losing today's counters on a crash or deploy is acceptable.

### Row format and positional updates

Each row is a 5-tuple: `{channel_id, date, received, processed, failed}`. Erlang's `update_counter/3` uses position indices (1-based in the ETS tuple):

```elixir
:ets.update_counter(@table, channel_id, {3, 1})  # received (position 3)
:ets.update_counter(@table, channel_id, {4, 1})  # processed (position 4)
:ets.update_counter(@table, channel_id, {5, 1})  # failed (position 5)
```

`update_counter` with a missing key raises. To handle the first increment of the day, `ChannelStats` uses `insert_new/2` with a zero-row as an `init` step, with a guard: if the stored date in position 2 doesn't match today, the row is replaced with a fresh zero-row before incrementing. This is checked lazily on each `incr_*` call — no scheduled reset needed.

### Retry queue depth

`get_today/1` also queries the DB for the count of `:pending` entries for the channel. This is the only DB query in the stats path and is done only when the UI reads stats (not on each message). It gives operators a live view of how backed up the retry queue is.

---

## CertParser and CertMonitor

`Joy.CertParser` uses Erlang's `:public_key.pkix_decode_cert/2` (OTP mode) to extract CN, issuer, SANs, and expiry from a PEM string without any external dependencies. Expiry is parsed from the X.509 `Validity.notAfter` field, which is either `utcTime` (YYMMDDHHMMSSZ, 2-digit year) or `generalTime` (YYYYMMDDHHMMSSZ). The 2-digit year ambiguity is resolved per the X.509 spec: 00–49 maps to 2000–2049, 50–99 maps to 1950–1999. SANs are extracted from the SubjectAltName extension; in OTP decode mode `:public_key` pre-decodes known extensions, so the SAN value is already a list of `{:dNSName, charlist}` tuples rather than a DER blob.

`tls_cert_expires_at` is populated when a cert is saved (in the `save_tls` LiveView event handler) so the database has a queryable datetime without needing to re-parse PEM on every check.

`Joy.CertMonitor` is a GenServer that fires once on startup and then every 24 hours via `Process.send_after`. It queries `Joy.Channels.list_tls_expiring_soon(30)` (a simple DB query against `tls_cert_expires_at`) and calls `Joy.Alerting.send_direct/3` for each channel that has alerting enabled. `send_direct` bypasses the ETS threshold/cooldown mechanism — cert expiry is time-based, not failure-count-based.

---

## Alerting: Consecutive Failure Detection

### ETS state

`Joy.Alerting` maintains an ETS table `{channel_id, consecutive_failures, last_alert_at}`. Rows are created on first failure and reset to 0 on any success:

- `record_failure/1` — increments `consecutive_failures`. If the count reaches `channel.alert_threshold` and the cooldown window has expired, fires an alert and updates `last_alert_at`.
- `record_success/1` — resets `consecutive_failures` to 0.

### Cooldown enforcement

The cooldown prevents alert storms: if 100 messages in a row fail, you should get one alert per cooldown period, not 96 alerts. The check is:

```elixir
seconds_since_last = DateTime.diff(DateTime.utc_now(), last_alert_at, :second)
if seconds_since_last >= channel.alert_cooldown_minutes * 60 do
  fire_alert(...)
  update_last_alert_at(channel_id)
end
```

`last_alert_at` is stored as a `DateTime` in ETS. On node restart, the ETS table is empty — the cooldown resets. This means a crash followed by immediate restart could fire an alert sooner than expected, but it cannot suppress alerts that should fire.

### Delivery

Two delivery mechanisms, both optional:

- **Email:** `Swoosh.Email.new/1` + `Joy.Mailer.deliver/1`. Uses whatever Swoosh adapter is configured (SMTP, Postmark, SendGrid, etc.). Fires when `channel.alert_email` is set.
- **Webhook:** `Req.post(url, json: payload)`. JSON payload includes channel ID, name, consecutive failure count, and timestamp. Fires when `channel.alert_webhook_url` is set. Both can be configured simultaneously.

If delivery fails (bad email config, unreachable webhook), the failure is logged but does not crash the Alerting GenServer. Alert delivery is best-effort.

---

## Message Search: Extract at Persist Time

### Why at persist time instead of query time?

The alternative would be to re-parse raw HL7 on every search query — either in the DB (using regex on the `raw_message` column) or in Elixir after a full table scan. Both approaches are expensive and scale poorly.

Extracting at `persist_pending` time costs one additional string operation per inbound message and stores two indexed varchar columns. Queries then become a simple `ilike` on an indexed column.

### Extraction without full HL7 parse

`message_type` is MSH.9 and `patient_id` is PID.3. Both can be extracted with simple string splitting, avoiding the full HL7 parser:

- For MSH.9: split the message on segment delimiter (`\r`), find the `MSH` segment, split on `|`, take index 8, take the first component (up to `^`).
- For PID.3: find the `PID` segment, split on `|`, take index 3, take the first component.

If either extraction fails (malformed message, segment absent), the field is left `nil` and the message is still persisted. Search just won't match on that field.

### `ilike` substring matching

`list_recent/2` uses PostgreSQL's `ilike` (case-insensitive `like`) with `%term%` wrapping. This supports partial matches: searching for `ADT` matches `ADT^A01^ADT_A01`, and searching for `12345` matches a patient ID like `12345^^^MRN`.

---

## Sinks: Design as a Test Tool

`Joy.Sinks` is a GenServer holding a `%{sink_name => [entries]}` map in its state. It is intentionally simple:

- **Node-local**: Sinks run on the node that received the message. If a channel is running on node B but you are looking at the Sinks UI connected to node A, you will see an empty list for that sink. This is acceptable for a testing tool; sinks are not production destinations.
- **Volatile**: Restart clears all sinks. Again, test tool — this is the right behavior.
- **Capped at 200 messages per sink** (`@max_messages`): `Enum.take([new | existing], 200)` prepends the new entry and truncates. This is a simple ring buffer. It prevents unbounded memory growth during load testing.
- **`cast` for writes, `call` for reads**: Writes are non-blocking (the adapter does not wait for the push to complete). Reads are synchronous (the LiveView needs the current state). This is the standard Elixir GenServer pattern for this access pattern.

The Sink adapter (`Joy.Destinations.Adapters.Sink`) calls `Joy.Sinks.push/2` synchronously in `deliver/2`, but the push is itself a cast — the adapter's `deliver` returns `:ok` immediately after sending the cast.

---

## Known Gaps

These are documented limitations in the current design that are worth knowing about.

**No key rotation for `ENCRYPTION_KEY`:** Rotating the key requires re-encrypting all `destination_configs.config` values. There is no tooling for this. A rotation would need to be done as a custom migration.

**No message log retention:** The `message_log_entries` table grows without bound. Retention policy enforcement requires an external cron job or scheduled database task.

**Pipeline blocks on slow destinations:** Retrying a slow destination blocks the Pipeline GenServer for the duration. High-latency destinations reduce channel throughput. Mitigations: use asynchronous destinations (SQS, SNS, Redis), keep `retry_attempts` low, or move to a pool-based pipeline model (future work).

**No channel pinning:** Horde distributes channels across nodes using a consistent hash ring. There is no mechanism to pin a channel to a specific node. This matters if you want to colocate specific channels for network proximity reasons, or if you want to control which node runs a channel during a rolling upgrade.

**Transform `set` does not enforce segment ordering:** Writing to a nonexistent segment appends it to the end of the segment list regardless of HL7 segment ordering rules. Most downstream systems are lenient about this, but strict validators may reject messages with segments in unexpected positions.

**`Joy.Sinks` is node-local:** Messages arrive at the sink on whichever node is running the channel. The Sinks UI shows the local node's sink state only. In a cluster, this means the UI may show empty sinks even when messages are flowing on another node.
