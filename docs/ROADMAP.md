# Joy Roadmap

## Completed (1–22)

| # | Feature |
|---|---|
| 1 | MLLP TLS — per-channel TLS with PEM storage, cert monitoring, expiry alerts |
| 2 | Source IP Allowlisting — per-channel and org-level CIDR allowlists |
| 3 | Dead Letter Queue UI — global failed message view, bulk and per-entry retry |
| 4 | Channel Pause/Resume — pipeline holds pending messages; MLLP server keeps accepting |
| 5 | Per-Channel Statistics — ETS-backed today counters (received/processed/failed) |
| 6 | Message Search — MSH.9 and PID.3 extracted at persist time; substring filter in log UI |
| 7 | Transform Testing / Preview — live editor with test input/output panel and AST sandbox |
| 8 | Alerting on Sustained Failures — consecutive-failure threshold with email + webhook delivery |
| 9 | Organizations — channel grouping with shared IP allowlist, alert config, TLS CA cert |
| 10 | Message Log Retention — archive-then-delete with LocalFS / S3 / Glacier backends |
| 11 | Pipeline Non-blocking Dispatch — ThousandIsland acceptors, configurable dispatch concurrency |
| 12 | Transform Segment Ordering — post-transform segment sort against canonical HL7 order |
| 13 | Sinks Cluster Distribution — PubSub-replicated sink events visible on all nodes |
| 14 | Encryption Key Rotation — `mix joy.rotate_key` with dual-read fallback during rotation window |
| 15 | Channel Pinning — Horde distribution strategy routes channel to a named cluster node |
| 16 | Non-Admin Read Access — two-tier auth; template + handler guards; no restart required |
| 17 | Audit Logging — immutable log of all admin mutations with actor, diff, and login events |
| 18 | ACK Customization — per-channel success code override and MSH.3/4 override |
| 19 | Metrics Export + Service Accounts — Prometheus endpoint; `joy_svc_` machine-actor tokens |
| 20 | Multi-Tenancy / Scoped Auth — org-scoped reads via `Scope.org_id/1`; 404 on cross-org access |
| 21 | REST API — full CRUD + lifecycle actions with Bearer token auth and OpenAPI spec |
| 22 | OpenAPI / Swagger Docs — machine-readable spec at `/api/v1/openapi.json`, UI at `/api/docs` |

---

## 23. Transform Replay ⏳ Planned

**Why:** Testing a transform change currently means saving it, waiting for a live message to arrive, and checking the result. Existing solutions provide a single static paste field for test input. It is less common for integration engines to let you validate a change against real recent production traffic before deploying it.

**Plan:**
- "Replay N messages" button in the transform editor (`editor_live.ex`) that fetches recent entries from `MessageLog.list_recent/2` for the channel
- Runs each entry's `raw_hl7` through the current (unsaved) script via `Joy.Transform.Runner` — same sandbox as production
- Displays a before/after panel per message with the diff highlighted
- No schema changes; no DB writes; pure preview execution

---

## 24. Silent-Channel / Absence Alerting ⏳ Planned

**Why:** Every integration engine alerts when messages fail. None natively alert when a *running* channel stops receiving messages entirely. In healthcare, a silent ADT feed almost always means a registration system is down, a VPN tunnel dropped, or an upstream sender crashed — a failure mode that consecutive-failure alerting can never catch (no messages = no failures to count).

**Plan:**
- Two new `channels` table columns: `silence_alert_enabled` (bool), `silence_alert_hours` (int, default 4)
- A GenServer (or extension of `Joy.Alerting`) runs hourly: for each running, silence-enabled channel, checks `ChannelStats.get_today/1`; if `received == 0` and the channel has been running longer than the threshold, fires an alert via the existing email/webhook delivery path
- Channel show page: silence alert config form alongside the existing failure threshold form
- Alert message distinguishes silence alerts from failure alerts

---

## 25. PHI Field Masking in Message Log UI ⏳ Planned

**Why:** The message log displays raw HL7, which contains patient names, DOBs, SSNs, and addresses. In a multi-user deployment, a support engineer debugging a routing issue shouldn't necessarily see full patient records. No HL7 integration engine implements display-layer PHI masking natively. Raw HL7 in the database is unaffected — masking is purely presentational.

**Plan:**
- New `masked_fields` jsonb column on `channels` (list of field references, e.g. `["PID.5.1", "PID.7", "PID.19"]`)
- Display-time rendering in `message_log/index_live.ex` and the message detail panel: parse each configured field ref, locate the value via the existing HL7 accessor, substitute with `[MASKED]`
- Channel show page: masked fields editor (add/remove field references with validation)
- Optional: admins always see full; non-admins see masked (per-channel toggle)

---

## 26. Patient Message Correlation View ⏳ Planned

**Why:** Debugging a patient data flow ("why didn't this patient's lab result arrive in system B?") currently requires searching the message log on each channel separately. `patient_id` is already extracted and indexed in `message_log_entries` — a unified patient view is one query away.

**Plan:**
- New `/patients` LiveView: search field for patient ID (substring match), results show all matching messages across all channels in chronological order
- Columns: received time, channel name, message type, status, expandable raw HL7
- Org-scoped naturally via channel join (existing `apply_org_filter` pattern)
- No schema changes

---

## 27. FHIR R4 / R5 Destination Adapter ⏳ Planned

**Why:** Healthcare is mid-migration from HL7 v2 to FHIR. Most organizations have legacy v2 senders and new FHIR-native systems side by side. A native v2→FHIR destination removes a painful middleware layer. FHIR R4 is the current deployed standard; R5 (published 2023) is emerging. A single adapter with a version selector avoids a future fork. Both are HL7 International open standards.

**Plan:**
- New adapter `Joy.Destinations.Adapters.FHIR`
- Config: `fhir_base_url`, `fhir_version` (`"R4"` | `"R5"`), auth (Bearer token or Basic, stored encrypted), transaction bundle vs individual resource POST
- Mapping modules per message type × FHIR version:
  - ADT^A01 / A08 → Patient + Encounter bundle
  - ORU^R01 → Observation + DiagnosticReport bundle
  - ORM^O01 → ServiceRequest bundle
- The existing HL7 v2 parser provides structured segment access; mapping logic reads segments directly
- Existing `Destinations.Retry` and destination config UI unchanged; only the adapter and its config form are new

---

## 28. Destination Circuit Breaker ⏳ Planned

**Why:** When a downstream system goes offline for hours, the current retry model generates a flood of failed entries and keeps worker slots occupied retrying a destination that will not answer. A circuit breaker detects the sustained outage, stops attempting delivery, and resurfaces a clean ordered queue when the destination recovers. Messages accumulate as `:pending` — the at-least-once guarantee ensures nothing is lost, including across a Joy restart.

**Plan:**
- ETS table holding circuit state per `destination_config.id`: `{:closed | :open | :half_open, failure_count, opened_at}`
- `Joy.Destinations` delivery path checks state before attempting; `:open` → skip delivery, message stays `:pending`
- On failure: increment counter; if counter >= threshold within sliding window, open the circuit
- On cooldown expiry: transition to `:half_open`; next delivery attempt is a probe — success closes circuit and drains queue, failure re-opens with reset cooldown
- Channel show page: circuit state badge per destination (Closed / Open / Half-open) with manual reset button

---

## 29. Kafka Destination Adapter ⏳ Planned

**Why:** Kafka is the backbone of most modern healthcare data platforms. Direct publish from the integration layer removes a separate Kafka producer service between Joy and the downstream data pipeline.

**Plan:**
- `brod` Elixir client (established library for Kafka)
- New adapter `Joy.Destinations.Adapters.Kafka`
- Config: broker list, topic, partition key field ref (e.g. `PID.3` for patient ID, or `MSH.4` for sending facility), SASL credentials (stored encrypted), payload format (raw HL7 or JSON-wrapped)

---

## 30. HTTP Inbound Source ⏳ Planned

**Why:** Modern senders — event-driven microservices, cloud functions, third-party SaaS integrations — don't speak MLLP. An HTTP inbound path lets Joy receive from any system that can make an HTTP POST, using the same pipeline, transforms, and message log as MLLP channels.

**Plan:**
- New Phoenix controller `InboundController` at `POST /inbound/:channel_token`
- Accepts raw HL7 (`Content-Type: text/plain`) or JSON-wrapped (`{"hl7": "MSH|..."}`)
- Returns HTTP 200 + ACK text on accept, 4xx on parse/auth failure
- Per-channel inbound token (random, stored hashed — same scheme as API tokens); displayed on the channel show page
- Feeds directly into `MessageLog.persist_pending/3` → Pipeline cast; no pipeline changes

---

## 31. Database Destination Adapter ⏳ Planned

**Why:** Analytics pipelines and reporting databases often need specific HL7 fields written to a SQL table directly — patient ID, message datetime, event type, sending facility — without a separate ETL step or Kafka consumer.

**Plan:**
- New adapter `Joy.Destinations.Adapters.Database`
- Config: connection string (stored encrypted), target table name, column mapping (jsonb list of `{hl7_field_ref, column_name}` pairs)
- Field extraction via existing HL7 accessor; `Postgrex` / `MyXQL` for delivery
- Configurable on-conflict behavior (`INSERT`, `INSERT OR IGNORE`, `UPSERT`)

---

## 32. HL7 Conformance Validation ⏳ Planned

**Why:** Bad senders produce malformed messages — missing required segments, empty required fields, invalid date formats — that fail silently in the pipeline. Surface validation errors early, before transforms run, so operators can distinguish "bad message from sender" from "Joy processing failure."

**Plan:**
- New `Joy.HL7.Validator` module with profile structs (required segments, required fields per segment, basic field type checks for TS/DT/NM/ID fields)
- Per-channel toggle (`validation_enabled`) and profile selection
- Validation runs in `MLLP.Connection` after parse, before persist
- On failure: message is persisted as `:failed` with a structured `error` describing which constraints were violated; no transform execution
- Option per channel: `validation_mode` — `"strict"` (fail immediately) or `"warn"` (pass through with error noted)

---

## 33. ACK Response Tracking (mllp_forward) ⏳ Planned

**Why:** When `mllp_forward` delivers a message to a downstream MLLP system, that system returns an ACK with an MSA.1 code (AA = accepted, AE = application error, AR = application reject). Currently only pass/fail is recorded. Storing the actual ACK code lets operators distinguish "downstream accepted" from "downstream rejected but ACK was received" — two very different failure modes.

**Plan:**
- New nullable `ack_code` varchar column on `message_log_entries`
- `mllp_forward` adapter extracts MSA.1 from the received ACK frame and returns it as part of the delivery result
- `Joy.Channel.Pipeline` stores the code when marking the entry processed or failed
- Message detail panel displays ACK code alongside transformed HL7

---

## 34. OAuth 2.0 / OIDC Authentication ⏳ Planned

**Why:** The existing password-based auth (phx.gen.auth) is not how most healthcare IT departments manage access. Enterprise environments authenticate via SSO — Azure AD, Okta, Google Workspace, Keycloak. Supporting OIDC means Joy plugs into whatever IdP the organization already operates, with no local password management, no shared credentials, and MFA inherited from the IdP. It is the expected baseline for any enterprise-deployed integration engine.

**Plan:**
- `ueberauth` + `ueberauth_oidcc` for the OIDC strategy (wraps the Erlang `oidcc` library, maintained by the Erlang Ecosystem Foundation — more spec-compliant than older Ueberauth OIDC strategies); individual provider strategies for Google, GitHub, Azure AD / Entra ID as needed
- On successful OIDC callback: look up or provision a local `users` record keyed on the IdP's `sub` claim; existing role/org assignments apply unchanged
- Admin UI: enabled providers list with client ID/secret config (stored encrypted); per-provider toggle
- Local password auth remains available — can be disabled org-wide for environments that require SSO-only
- No schema changes to the authorization model; OIDC is purely an authentication path into the existing `Scope`-based system
- Ueberauth success → phx.gen.auth database session (same session system as password auth, different entry point); JWT tokens for API use only (item 36)

---

## 35. LDAP / Active Directory Authentication ⏳ Planned

**Why:** Many hospital networks still authenticate everything against Active Directory or OpenLDAP. OIDC requires a modern IdP layer in front of AD (ADFS, Azure AD Connect, etc.) that not all smaller facilities have. Native LDAP bind lets Joy authenticate directly against the directory every organization already has, with no middleware. Group membership in AD maps naturally to Joy's admin/read-only roles.

**Plan:**
- `exldap` (or `eldap` from OTP stdlib) for LDAP bind and search
- Config: `ldap_host`, `ldap_port`, `ldap_base_dn`, `ldap_bind_dn` + password (stored encrypted), `ldap_user_filter`, optional `ldap_admin_group_dn` and `ldap_readonly_group_dn`
- Auth flow: bind with service account → search for user DN by username → bind again as the user with their password to verify credentials → check group membership for role assignment
- On success: look up or provision a local `users` record; role derived from group membership, overridable by a local admin
- Admin UI: LDAP config form with a "Test connection" button that runs a search with the service account credentials
- Existing password auth remains available as fallback during LDAP migration

---

## 36. Guardian JWT API Tokens ⏳ Planned

**Why:** The current service account tokens (`joy_svc_*`) are opaque random strings verified by a DB lookup on every API request. Replacing them with Guardian-issued JWTs makes verification stateless — no roundtrip to the DB per request — and embeds claims (`org_id`, `role`, `type`) directly in the token so the request handler has full context without additional queries. This also gives external systems a standard Bearer JWT they can introspect rather than an opaque string.

**Why not JWT for web sessions:** JWTs cannot be immediately revoked without a server-side blocklist. The existing phx.gen.auth database-backed sessions revoke instantly on logout, which is the correct behavior for browser sessions. Guardian is used for API tokens only; web sessions remain database-backed. Ueberauth (items 34/35) authenticates users via OAuth/LDAP and then lands them in the same phx.gen.auth session — no JWT involved in the browser flow.

**Plan:**
- `joken` for JWT signing and verification (lighter than Guardian; does exactly what's needed without the framework overhead — no subjects, permissions, or plug abstractions required)
- JWT claims: `sub` (service account ID), `typ` (`"service_account"`), `org_id`, `role`, `jti` (UUID, for revocation)
- Replace opaque `joy_svc_*` token generation with `Joken.generate_and_sign/3`; token displayed once at creation, not stored — only the `jti` is persisted for revocation tracking
- API auth plug: verify JWT signature + check `jti` not in revocation set → build `Scope` from claims (no DB lookup for valid non-revoked tokens)
- Token revocation: small `revoked_tokens` table (`jti`, `revoked_at`); pruned automatically when `exp` passes
- Admin UI: service account token management updated to show JWT issuance; existing list/revoke UI unchanged in appearance
