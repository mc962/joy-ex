# Joy Roadmap

Features not yet implemented, ordered by priority. Security and operational reliability items come first given Joy's healthcare context.

---

## 1. MLLP TLS

**Why first:** MLLP sends raw HL7 over TCP — PHI travels in plaintext. HIPAA requires encryption in transit. Every other improvement is secondary to this in a production deployment.

**What's needed:**
- Replace `Ranch` `:ranch_tcp` transport with `:ranch_ssl` in `Joy.MLLP.Server`
- Per-channel TLS config: cert path, key path, optional CA/client cert for mutual TLS
- Store cert paths (or PEM content) in `destination_configs` or a new `channel_tls_config` table — encrypt private key at rest with the existing `Joy.Encrypted.MapType`
- Dev/test: accept self-signed certs; production: Let's Encrypt or org CA

---

## 2. Source IP Allowlisting per Channel

**Why second:** Prevents unauthorized parties from injecting HL7 messages into a channel's MLLP port. Without this, anyone who can reach the port can send messages.

**What's needed:**
- Add `allowed_ips` field to `channels` table (list of CIDR strings, null = allow all)
- In `Joy.MLLP.Connection.init/1`, call `:inet.peername/1`, check against the allowlist, close socket with a log warning if rejected
- UI: editable IP allowlist on the channel show/edit page

---

## 3. Dead Letter Queue UI

**Why third:** After `max_retries` exhausted, `:failed` entries sit silently in the DB. In healthcare, a permanently failed message may mean a patient record didn't update. Someone needs to see it and act on it.

**What's needed:**
- Dashboard widget: count of `:failed` entries across all channels, links to the offending channel logs
- On the message log page: "Retry All Failed" bulk action button
- Consider a global `/messages/failed` view across all channels for admins
- No new data model needed — `status: "failed"` entries already exist

---

## 4. Channel Pause/Resume

**Why fourth:** Planned maintenance on a downstream system shouldn't require deleting and recreating a channel. Pausing stops the pipeline from processing new messages while still accepting and logging them (so nothing is lost).

**What's needed:**
- Add `status` field to `channels` table: `:active` | `:paused`
- When paused: MLLP server continues accepting connections and persisting messages (at-least-once still holds), but the pipeline does not dispatch
- When resumed: pipeline requeues all `:pending` entries (same logic as startup)
- `Joy.ChannelManager`: `pause_channel/1` and `resume_channel/1`
- UI: pause/resume button on channel show page with clear visual state indicator

---

## 5. Per-Channel Statistics

**Why fifth:** Operators need quantitative visibility — "Channel ADT: 1,247 messages today, 3 failed" — without querying the DB directly.

**What's needed:**
- Lightweight counters: messages received today, processed today, failed today, current retry queue depth
- Options: ETS counters (fast, lost on restart, fine for "today" stats) or DB aggregates (durable, slightly slower)
- Recommend: ETS for live counters (reset on node restart is acceptable), DB for historical daily roll-ups
- Surface on: channel show page and dashboard cards
- Stretch: simple sparkline of message volume over the last 24h

---

## 6. Message Search

**Why sixth:** The message log has status filtering but no way to find a specific patient's messages or a specific message type. "Did this patient's lab result arrive?" currently requires a DB query.

**What's needed:**
- Filter by: message type/event (MSH.9, e.g. `ADT^A01`), patient ID (PID.3 or PID.5), date range, message control ID substring
- Implementation: index `raw_hl7` is not practical; better to extract `message_type` and `patient_id` at persist time into dedicated columns on `message_log_entries`
- Migration: add `message_type varchar`, `patient_id varchar` columns; populate from `MSH.9` and `PID.3` during `persist_pending/3`
- UI: filter bar above the message log table

---

## 7. Transform Testing / Preview

**Why seventh:** Currently a transform must be saved and a live message must arrive to test it. This creates a slow feedback loop and risks deploying a broken transform to production.

**What's needed:**
- UI panel on the transform editor: paste a sample HL7 message, click "Run", see the transformed output (or error with line number)
- Backend: new controller/LiveView action that calls the existing `Joy.Transform.Runner` sandbox directly — no DB writes, no pipeline dispatch
- The sandbox (`Task.Supervisor.async_nolink`, 5s timeout, AST whitelist) already exists; this is purely a UI addition

---

## 8. Alerting on Sustained Failures

**Why last:** Important for production, but the other gaps are more immediately impactful. Without alerting, a broken channel can go unnoticed for hours.

**What's needed:**
- Trigger: N consecutive failures on a channel (configurable, default 5), or failure rate > X% in a rolling window
- Delivery: email via the existing `Joy.Mailer` / Swoosh setup; optionally a webhook (POST to a configured URL)
- Per-channel alert config: enabled/disabled, threshold, recipient email or webhook URL
- Implementation: track consecutive failure count in ETS (reset on success); check threshold in `Joy.Channel.Pipeline` after `mark_failed/2`
- Cooldown: don't re-alert for the same channel within N minutes to avoid alert fatigue
