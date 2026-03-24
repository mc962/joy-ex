# Joy Roadmap

Items 1–18 are complete. Items 19–22 are the next wave, in rough priority order.

---

## 1. MLLP TLS ✅ Implemented

**Why first:** MLLP sends raw HL7 over TCP — PHI travels in plaintext. HIPAA requires encryption in transit. Every other improvement is secondary to this in a production deployment.

**What was built:**
- `Joy.MLLP.Server` branches on `channel.tls_enabled`: uses `:ssl.transport_accept/1` + `:ssl.handshake/1` for TLS, `:gen_tcp.accept/1` for plain TCP
- `Joy.MLLP.Connection` carries the transport (`:gen_tcp` | `:ssl`) in state; handles `{:ssl, ...}` / `{:tcp, ...}` active-mode messages accordingly
- Per-channel TLS config stored as PEM content in the database (not file paths): `tls_cert_pem`, `tls_key_pem` (encrypted at rest via `Joy.Encrypted.StringType`), `tls_ca_cert_pem`, `tls_verify_peer`, `tls_cert_expires_at`
- `Joy.CertParser` extracts CN, issuer, SANs, and expiry from PEM using `:public_key` — no external deps
- `Joy.CertMonitor` GenServer runs a daily check; fires alerts via `Joy.Alerting.send_direct/3` for certs expiring within 30 days
- Channel show page: TLS config form with PEM textareas; write-only private key (replace button); cert info panel (CN, issuer, SANs, expiry, days remaining); expiry warning badge; "Copy cert" button for sharing with connecting systems
- Dashboard: cert expiry warning banner lists channels with certs expiring within 30 days
- MLLP test client and stress test tool support TLS connections (`tls: true` opt, `verify: :verify_none`) so channels with TLS enabled can be tested from the UI
- Dev/test: `mix phx.gen.cert` produces `priv/cert.pem` and `priv/key.pem` that can be pasted directly into the channel TLS form

---

## 2. Source IP Allowlisting per Channel ✅ Implemented

**Why second:** Prevents unauthorized parties from injecting HL7 messages into a channel's MLLP port. Without this, anyone who can reach the port can send messages.

**What was built:**
- `allowed_ips` field on `channels` table (list of CIDR strings, empty = allow all)
- In `Joy.MLLP.Connection.init/1`, calls `:inet.peername/1` (or `:ssl.peername/1` for TLS), checks against the allowlist, closes socket with a log warning if rejected
- Supports plain IPs (`10.0.0.5`) and CIDR ranges (`10.0.0.0/24`)
- UI: editable IP allowlist on the channel show page

---

## 3. Dead Letter Queue UI ✅ Implemented

**Why third:** After `max_retries` exhausted, `:failed` entries sit silently in the DB. In healthcare, a permanently failed message may mean a patient record didn't update. Someone needs to see it and act on it.

**What was built:**
- Dashboard widget: total count of all `:failed` entries across all channels (from DB), with a "View all" link when count is non-zero
- Message log page: "Retry All Failed (N)" bulk action button that marks all failed entries as `:retried`, inserts fresh `:pending` entries, and dispatches them to the pipeline
- Global `/messages/failed` view across all channels: shows channel name, message type, patient ID, error, with per-entry retry

---

## 4. Channel Pause/Resume ✅ Implemented

**Why fourth:** Planned maintenance on a downstream system shouldn't require deleting and recreating a channel. Pausing stops the pipeline from processing new messages while still accepting and logging them (so nothing is lost).

**What was built:**
- `paused` boolean on the `channels` table (default false)
- When paused: MLLP server continues accepting connections and persisting messages (at-least-once still holds); Pipeline receives `{:process, _}` casts but silently holds them — messages stay `:pending` in DB
- When resumed: Pipeline reloads config and requeues all `:pending` entries via `list_pending` (same logic as startup)
- `Joy.ChannelManager.pause_channel/1` and `resume_channel/1`
- Dashboard and channel show page: Pause/Resume buttons; "Paused" badge distinct from "Running"

---

## 5. Per-Channel Statistics ✅ Implemented

**Why fifth:** Operators need quantitative visibility — "Channel ADT: 1,247 messages today, 3 failed" — without querying the DB directly.

**What was built:**
- `Joy.ChannelStats` GenServer backed by ETS table `{channel_id, date, received, processed, failed}`
- Counters reset automatically when the date rolls over (detected lazily on read); lost on node restart — acceptable for live "today" metrics
- `incr_received/1` called from `Joy.MLLP.Connection` on each message arrival; `incr_processed/1` and `incr_failed/1` called from `Joy.Channel.Pipeline`
- Retry queue depth queried from DB on demand (count of `:pending` entries for the channel)
- Dashboard: Today Recv / Proc / Fail columns in the channel table
- Channel show page: today stat row (received, processed, failed, queue depth) + session failure count

---

## 6. Message Search ✅ Implemented

**Why sixth:** The message log has status filtering but no way to find a specific patient's messages or a specific message type. "Did this patient's lab result arrive?" currently requires a DB query.

**What was built:**
- `message_type varchar` and `patient_id varchar` columns on `message_log_entries`, with indexes
- Extracted at `persist_pending` time from MSH.9 (message type) and PID.3 (patient ID) — no re-parsing on search
- `Joy.MessageLog.list_recent/2` accepts `message_type:`, `patient_id:`, `date_from:`, `date_to:` opts with `ilike` substring matching
- Message log page: search bar (message type + patient ID) with Submit and Clear; table adds Patient ID column

---

## 7. Transform Testing / Preview ✅ Implemented

**Why seventh:** Currently a transform must be saved and a live message must arrive to test it. This creates a slow feedback loop and risks deploying a broken transform to production.

**What was built:**
- The transform editor (`/channels/:id/transforms/:transform_id/editor`) has a three-panel layout: script (left), test input (top right), output (bottom right)
- "Run" button parses the test input as HL7, executes the current script via `Joy.Transform.Runner` in the existing sandbox (no DB writes, no pipeline dispatch), and shows the transformed output or error with line number
- The sandbox is identical to production execution: `async_nolink` Task under `Joy.TransformSupervisor`, 5s timeout, AST whitelist validation

---

## 8. Alerting on Sustained Failures ✅ Implemented

**Why last:** Important for production, but the other gaps are more immediately impactful. Without alerting, a broken channel can go unnoticed for hours.

**What was built:**
- `Joy.Alerting` GenServer backed by ETS table `{channel_id, consecutive_failures, last_alert_at}`
- `record_failure/1` increments the counter and fires an alert when the threshold is reached, respecting the per-channel cooldown window
- `record_success/1` resets the consecutive failure counter on any successful message
- Alert delivery: email via `Joy.Mailer` / Swoosh when `alert_email` is configured; HTTP webhook POST (JSON payload) via `Req` when `alert_webhook_url` is configured
- Per-channel config on the `channels` table: `alert_enabled`, `alert_threshold` (default 5), `alert_email`, `alert_webhook_url`, `alert_cooldown_minutes` (default 60)
- Channel show page: alert configuration form

---

## 9. Organizations (Channel Grouping) ✅ Implemented

**Why:** As channel counts grow, operators need to group them by health system for navigation, shared config, and aggregate visibility.

**What was built:**
- `organizations` table with name, slug (auto-generated, unique), description, shared `allowed_ips`, `alert_email`, `alert_webhook_url`, `tls_ca_cert_pem`
- Nullable `organization_id` FK on `channels` (nilify_all) and `users` (foundation for future scoped auth)
- `Joy.Organizations` context with full CRUD and PubSub on `"organizations"` topic
- `Joy.IPValidator` extracted from `Channel` and shared with `Organization` changeset
- `Joy.Channels.effective_allowed_ips/1` unions channel + org IP allowlists; used by `MLLP.Connection`
- `Joy.Alerting` falls back to org-level `alert_email`/`alert_webhook_url` when channel has none
- Dashboard: channels grouped by org with aggregate recv/proc/fail stats per group
- Channels index: Org column + org dropdown in create/edit modal
- `/organizations` and `/organizations/:id` LiveViews (list, create, show with IP/alert/TLS sections)

---

## 10. Message Log Retention ✅ Implemented

**Why:** The `message_log_entries` table grows without bound. PHI retention policies (HIPAA, state law) require data to be purged after a defined window. Long-running tables also degrade query performance.

**What was built:**
- `retention_settings` table (single-row config): retention window, schedule toggle, archive destination + credentials
- Three archive backends behind a common `Joy.Retention.Archive` behaviour: `LocalFS`, `S3`, `Glacier` (S3 GLACIER storage class)
- `ex_aws_s3` added for S3/Glacier uploads; credentials stored encrypted at rest via `Joy.Encrypted.StringType`
- `Joy.Retention.run_purge/1` archives then deletes entries older than the retention window (excluding `:pending`); `all: true` option purges everything non-pending
- Archives written as gzip-compressed NDJSON in 50k-entry chunks; safe to re-run (archive before delete, abort on archive failure)
- `Joy.Retention.Scheduler` GenServer runs a daily purge at the configured UTC hour; duplicate-run protection via `last_purge_at` timestamp
- `/tools/retention` LiveView: entry counts + oldest entry, settings form with conditional AWS/path fields, one-click purge with async progress, purge-all confirm modal, last-run summary

---

## 11. Pipeline Non-blocking Dispatch ✅ Complete

- Pipeline GenServer never blocks on I/O — each message is executed in a worker task under `Joy.Channel.WorkerSupervisor` (a per-channel `Task.Supervisor` added to the channel OTP tree at index [0])
- `dispatch_concurrency` field on channels (default 1, max 20) controls how many tasks may run simultaneously; configurable per channel in the UI under the "Dispatch" section
- `concurrency = 1` preserves strict FIFO ordering (same guarantee as before, but the GenServer is now non-blocking); `concurrency > 1` allows parallel dispatch across senders at the cost of cross-sender ordering
- Local FIFO queue in Pipeline state (`pending_queue`) buffers messages when all slots are in use; GenServer mailbox provides outer backpressure
- MLLP.Server migrated from a hand-rolled single-acceptor loop to **ThousandIsland** (already a transitive dep via Bandit), eliminating serialized TLS handshakes — 100 acceptors handle simultaneous TLS handshakes in parallel; stress test of 500 messages at 100 concurrent TLS connections went from ~10% failures to 0

---

## 12. Transform Segment Ordering ⏳ Planned

**Why:** The `set` DSL function appends new segments to the end of the message, regardless of the canonical HL7 segment order. Most downstream systems are lenient, but strict validators (e.g. HL7 FHIR converters, some EHR interfaces) reject messages with segments out of order.

**Plan:** Maintain a known-order map for standard HL7 v2 segment types (MSH, EVN, PID, PV1, OBR, OBX, …). After a transform runs, sort the segment list against this map, preserving relative order for unknown/repeated segments.

---

## 13. Sinks Cluster Distribution ⏳ Planned

**Why:** `Joy.Sinks` is a node-local ETS-backed GenServer. In a multi-node cluster, the UI on node A shows an empty sink if the channel is running on node B. This makes the Sinks tool unreliable in production deployments.

**Plan:** Replace node-local ETS with a Horde-registered global sink store, or use Phoenix PubSub to replicate push events to all nodes so every node's UI reflects the full picture.

---

## 14. ENCRYPTION_KEY Rotation ✅ Implemented

**Why:** Rotating the AES-256-GCM key currently requires a custom migration script to re-encrypt all `destination_configs.config` values and any other encrypted fields. There is no tooling for this, making rotation operationally risky.

**What was built:**
- `mix joy.rotate_key --old-key OLD_B64 --new-key NEW_B64 [--batch-size N]` — re-encrypts all four encrypted fields (`channels.tls_key_pem`, `destination_configs.config`, `retention_settings.aws_access_key_id`, `retention_settings.aws_secret_access_key`) in cursor-based batches, each in its own short transaction; aborts before touching anything if the old key fails a pre-flight decrypt check
- Dual-read fallback in `Joy.Crypto.decrypt/1` — if `ENCRYPTION_KEY_OLD` env var is set, a failed decrypt with the primary key automatically retries with the old key; covers the window between deploying new code and running the rotation task
- `ENCRYPTION_KEY_OLD` read from env in `config/runtime.exs`

---

## 15. Channel Pinning ✅ Implemented

**Why:** Horde distributes channel supervisor trees across nodes using a consistent hash ring. There is no way to pin a channel to a specific node — useful for network proximity (e.g. a channel serving a device on a specific subnet), or for controlled rolling upgrades where you want to drain one node before taking it down.

**What was built:**
- `pinned_node` nullable string field on `channels` table
- `Joy.PinnedDistribution` — custom `Horde.DistributionStrategy`; when the child spec carries a non-nil `pinned_node`, routes placement to the named alive cluster member; falls back to `Horde.UniformDistribution` if the node isn't in the cluster (`String.to_existing_atom` prevents garbage atom creation for disconnected nodes)
- `Joy.Channel.Supervisor.child_spec/1` passes `pinned_node` from the channel struct into the child spec map so the distribution module can inspect it at `start_child` time
- `Joy.ChannelSupervisor` configured with `distribution_strategy: Joy.PinnedDistribution`
- Channel show page: node picker dropdown (admin-only) populated from `[node() | Node.list()]`; saving restarts the channel if running so Horde re-places it on the pinned node
- IP Allowlist and TLS Configuration sections also restricted to admin users (template guard + event handler check), forward-proofing for when non-admin read access is added

---

## 16. Non-Admin Read Access ✅ Implemented

**Why:** Every authenticated user previously required `is_admin: true` via the blanket `JoyWeb.AdminAuth` on-mount hook. In a real deployment, operators (on-call, support, read-only observers) need to view the dashboard, message logs, and channel status without the ability to change configuration.

**What was built:**
- Router split into two live sessions: `:app` (any authenticated user) and `:admin` (requires `is_admin` via `JoyWeb.AdminAuth`). Admin-only routes (`/users`, `/tools/*`) moved to `:admin`. All channel, organization, and message routes remain in `:app`.
- Defense-in-depth: template guards (`if @current_scope.user.is_admin`) hide admin-only controls; event handler guards (`if admin?(socket)`) block mutations even from crafted WebSocket messages.
- Non-admin view: dashboard shows channel list read-only; channel show displays status, stats, transforms list, and destinations list — no add/edit/delete buttons; no IP allowlist, TLS, Alerting, Dispatch, or Node Pinning sections.
- Message retry (`retry`, `retry_all_failed`) is intentionally NOT admin-gated — on-call and support staff can retry failed messages as a recovery action.
- Simplify fixes bundled in: stale `socket.assigns.running?` in `save_pin` replaced with `Joy.ChannelManager.channel_running?`; duplicated stop+restart logic extracted to `restart_if_running/2` private helper (used by `save_tls` and `save_pin`); `Joy.Crypto.encrypt_with/2` and `decrypt_with/2` promoted to public; `mix joy.rotate_key` removes its duplicate crypto and delegates to `Joy.Crypto`.

---

## 17. Audit Logging ✅ Implemented

**Why:** There is no record of who changed what or when. In a HIPAA context, configuration changes to encryption keys, TLS certificates, IP allowlists, and retention settings are material events that should be traceable to a specific user and timestamp.

**What was built:**
- `audit_log_entries` table: `actor_id` (nilify_all FK), `actor_email` (denormalized — survives user deletion), `action`, `resource_type`, `resource_id`, `resource_name`, `changes` (jsonb), `inserted_at`; indexes on actor_id, resource_type, inserted_at; no `updated_at` — entries are immutable
- `Joy.AuditLog.Entry` schema and `Joy.AuditLog` context: `log/6` inserts entries; `list_entries/1` with keyword opts filtering (resource_type, actor_id, from, to, limit)
- Call sites at every admin-gated mutation: all channel start/stop/pause/resume, TLS config, alert config, dispatch config, node pinning, IP allowlist add/remove, transform create/update/delete/toggle, destination create/update/delete/toggle; org create/update/delete, org IP/alert/TLS; user promote/demote; all dashboard start/stop/pause/resume
- Sensitive fields never logged: TLS PEM content and destination credentials are excluded; TLS saves log only `%{tls_enabled, cert_updated, key_updated}` booleans
- `/audit` admin-only LiveView: table with Time, Actor, Action, Resource, Changes columns; filter form (resource_type dropdown, date-from/to inputs, submits on change); color-coded action badges (created=success, deleted=error, started/resumed=success, stopped/paused=warning)
- Login logging: `user.login` and `user.login_failed` on every authentication attempt (password + magic-link); `changes` includes method and remote IP. Used as a proxy for PHI read access — per-read logging considered but rejected as too noisy; full rationale and trade-offs in `docs/design.md`
- `audit_retention_days` integer column on `retention_settings` (default 365); `Joy.AuditLog.purge_old/1`, `count_total/0`, `count_purgeable/1`
- Retention settings (configurable window + manual purge button) available on the `/audit` page; audit retention is independent of message log retention
- Channel edit `changes` field now logs the actual diff of changed fields rather than hardcoded `mllp_port`

---

## 18. HL7 Acknowledgement Customization ✅ Implemented

**Why:** Joy previously returned a hardcoded AA (Application Accept) ACK for every received message. Some downstream interfaces require AE or AR responses, and some systems need custom MSH fields (sending application, facility) in the ACK to route it correctly.

**What was built:**
- `ack_code_override`, `ack_sending_app`, `ack_sending_fac` columns on `channels` table
- `Joy.MLLP.Framer.build_ack/3` accepts optional `sending_app` / `sending_fac` overrides; nil values fall back to mirroring inbound MSH.5/MSH.6 (existing behaviour)
- `Joy.MLLP.Connection.send_ack/4` resolves the ACK code via `ack_code/2`: if `ack_code_override` is set it replaces the success-path AA; error ACKs (AE for parse/persist failure) are never overridden
- Channel show page: ACK Configuration section with success code dropdown and MSH.3/4 text inputs; changes take effect for new connections only (noted in UI); saves are audit-logged as `channel.ack_updated`

---

## 19. Metrics Export ⏳ Planned

**Why:** `Joy.ChannelStats` tracks per-channel received/processed/failed counts in ETS but the data is only visible in the LiveView dashboard. Production deployments need to scrape these metrics into Prometheus or push them to an OpenTelemetry collector for alerting and long-term trending — without polling the web UI.

**Plan:** Add a `/metrics` endpoint (Plug, outside the authenticated LiveView scope) that emits Prometheus text format: `joy_channel_messages_total{channel, status}` counters and a `joy_channel_queue_depth{channel}` gauge. Wire `Joy.ChannelStats` to also emit telemetry events so an optional OpenTelemetry exporter can consume them without changing the scrape path.

---

## 20. Multi-Tenancy / Scoped Auth ⏳ Planned

**Why:** `organization_id` is already a foreign key on both `users` and `channels`, but it is not enforced in any query — a user belonging to org A can see and modify channels belonging to org B. This is acceptable in a single-tenant deployment but blocks any multi-tenant or white-label use.

**Plan:** Thread `current_scope` (already carrying `user` and `organization_id`) through all context queries. `Joy.Channels.list_channels/1`, `get_channel!/2`, and all mutations gain a scope argument and add `WHERE organization_id = $n` (or allow nil org to see everything, preserving single-tenant behaviour). Admin users bypass org scoping. Update LiveViews to pass `current_scope` into context calls.

---

## 21. REST API Layer ⏳ Planned

**Why:** The LiveView UI is the only way to manage Joy today. Integrators need to provision channels, manage destinations, trigger retries, and query message log entries programmatically — for IaC tooling, CI pipelines, and embedding Joy into broader platform automation.

**Plan:** Add a `/api/v1` scope in the router protected by Bearer token authentication (API keys stored as hashed tokens in a new `api_tokens` table, scoped to a user or org). Expose JSON endpoints covering the core resources: channels (CRUD, start/stop/pause/resume), organizations (CRUD), destinations (CRUD), message log (list, retry), and retention (trigger purge). Controller logic delegates to the existing context modules — no new business logic, just a new transport layer. API tokens are managed from the user settings page.

---

## 22. OpenAPI / Swagger Docs ⏳ Planned

**Why:** A REST API without a machine-readable schema forces integrators to read source code. An OpenAPI spec enables generated client SDKs, Postman collections, and in-browser interactive docs with no extra integration work.

**Plan:** Add `open_api_spex` as a dependency. Annotate API controllers with request/response schemas. Expose the spec at `/api/v1/openapi.json` and mount Swagger UI at `/api/docs` (unauthenticated, read-only). Schemas live in `lib/joy_web/api/schemas/` alongside the controllers. Implement item 21 first — OpenAPI annotations are added as part of or immediately after the controller layer is in place.
