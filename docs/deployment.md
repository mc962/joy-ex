# Deploying Joy

Joy is a self-hosted HL7 v2.x integration engine. This guide covers everything you need to run it in production — from a single node to a multi-node HA cluster — across Docker Compose, bare metal, and Amazon ECS.

> **Healthcare note:** Joy's message log stores raw HL7 messages, which contain Protected Health Information (PHI). This document calls out specific PHI-related considerations throughout. Read the [Security](#security) section before going live.

## Contents

- [Prerequisites](#prerequisites)
- [Environment Variables](#environment-variables)
- [Building a Release](#building-a-release)
- [First-Time Setup](#first-time-setup)
- [Deployment Targets](#deployment-targets)
  - [Single Node](#single-node)
  - [Docker Compose](#docker-compose)
  - [Bare Metal / EC2](#bare-metal--ec2)
  - [Amazon ECS](#amazon-ecs)
- [Clustering](#clustering)
- [MLLP and Load Balancers](#mllp-and-load-balancers)
- [Database](#database)
- [Security](#security)
- [Upgrading](#upgrading)
- [Day-Two Operations](#day-two-operations)

---

## Prerequisites

| Requirement | Notes |
|---|---|
| PostgreSQL 14+ | Stores channels, transforms, message log (contains PHI), user accounts |
| Elixir 1.18 / OTP 26 | Only needed to build; not needed at runtime when using Docker |
| A 32-byte secret key | For encrypting destination credentials at rest — see below |

---

## Environment Variables

These must be set at runtime (not baked into the image). Store them as secrets in your deployment platform (AWS Secrets Manager, SSM Parameter Store, Doppler, etc.) — never commit them to source control.

### Required everywhere

| Variable | Description | How to generate |
|---|---|---|
| `DATABASE_URL` | Ecto database URL | `ecto://user:pass@host/dbname` |
| `SECRET_KEY_BASE` | Signs/encrypts Phoenix cookies and sessions | `mix phx.gen.secret` |
| `ENCRYPTION_KEY` | AES-256-GCM key for destination credentials (API keys, passwords, etc.) stored in the DB | `iex -e ":crypto.strong_rand_bytes(32) |> Base.encode64() |> IO.puts"` |
| `PHX_SERVER` | Set to `true` to start the HTTP server | Always `true` in production |
| `PHX_HOST` | Public hostname for URL generation (e.g. `joy.example.com`) | Your domain |

### Required in a cluster (2+ nodes)

| Variable | Description | How to generate |
|---|---|---|
| `RELEASE_COOKIE` | Shared secret that authenticates Erlang cluster members. **Must be identical across all nodes.** A node with a different cookie is silently rejected. | `mix phx.gen.secret 32` |
| `DNS_CLUSTER_QUERY` | DNS name that resolves to all node IPs. Joy queries this on boot and connects to every IP it finds. | See [Clustering](#clustering) |

### Optional

| Variable | Default | Description |
|---|---|---|
| `PORT` | `4000` | HTTP port |
| `POOL_SIZE` | `10` | Ecto DB connection pool size per node. Total connections = `POOL_SIZE × num_nodes`. |
| `ECTO_IPV6` | unset | Set to `true` to connect to the database over IPv6 |

---

## Building a Release

Joy uses Elixir's standard `mix release` to produce a self-contained binary (no Elixir or Mix required at runtime).

**With Docker (recommended):**

```sh
docker build -t joy:latest .
```

The `Dockerfile` is a two-stage build: compile in a full Elixir image, then copy the release into a minimal Debian runtime image. The final image is ~100MB.

**Without Docker:**

```sh
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
# Binary is at _build/prod/rel/joy/bin/joy
```

---

## First-Time Setup

These steps run once when you deploy to a new database.

### 1. Run migrations

Migrations must be run before starting the application. With Docker:

```sh
docker run --rm --env-file .env joy:latest bin/migrate
```

Without Docker:

```sh
DATABASE_URL=... SECRET_KEY_BASE=... ENCRYPTION_KEY=... _build/prod/rel/joy/bin/joy eval "Joy.Release.migrate()"
```

**In a cluster:** Run migrations once from any single node before the rest of the cluster starts. Ecto's Postgres advisory lock mechanism prevents concurrent migrations if multiple nodes somehow start simultaneously, but the cleanest approach is a separate one-shot "migrate" task before any application nodes start. In ECS, this is a one-off ECS Task run as a dependency before the service starts.

### 2. Create your first admin user

Joy requires all users to be promoted to admin before they can access the application. Self-registration creates non-admin accounts by default.

```sh
# First register a user via the web UI at /users/register
# Then promote them:
docker run --rm --env-file .env joy:latest bin/joy eval "Joy.Release.migrate()"

# Or, from a running node:
docker exec -it <container> bin/joy rpc "Mix.Tasks.Joy.MakeAdmin.run([\"user@example.com\"])"
```

If running a release (not Mix), use the IEx remote shell:

```sh
bin/joy rpc "Joy.Accounts.get_user_by_email!(\"user@example.com\") |> Ecto.Changeset.change(%{is_admin: true}) |> Joy.Repo.update!()"
```

---

## Deployment Targets

### Single Node

The simplest deployment. No clustering configuration required — Horde runs as a single-member cluster automatically when `DNS_CLUSTER_QUERY` is not set.

Start with the `server` script generated by `mix phx.gen.release`:

```sh
PHX_SERVER=true DATABASE_URL=... SECRET_KEY_BASE=... ENCRYPTION_KEY=... bin/server
```

Or with Docker:

```sh
docker run -d \
  --name joy \
  -p 4000:4000 \
  -p 2575:2575 \   # expose any MLLP ports your channels use
  --env-file .env \
  joy:latest
```

A single node has no automatic failover. If the process dies, channels are down until it restarts. For healthcare workloads with uptime requirements, use at least two nodes.

---

### Docker Compose

The included `docker-compose.yml` runs a two-node cluster backed by a local Postgres instance. Intended for local development, integration testing, or a single-machine deployment where you want to exercise the clustering logic.

```sh
# Build the image
docker compose build

# Run migrations (once, before starting the cluster)
docker compose run --rm joy1 bin/migrate

# Start the cluster
docker compose up
```

Node 1 is accessible at `http://localhost:4000`, node 2 at `http://localhost:4001`.

**How clustering works in Compose:** Both `joy1` and `joy2` share the Docker network alias `joy`. When either node's `dns_cluster` queries `joy`, Docker's embedded DNS returns both container IPs as A records. The nodes connect and form a cluster. `rel/env.sh.eex` sets each node's name to `joy@<container-IP>`, which matches the IPs `dns_cluster` resolved.

**Important:** Compose on a single machine is not true HA — if the machine dies, all nodes die. For real redundancy, nodes must run on separate machines.

---

### Bare Metal / EC2

For a static set of VMs (dedicated servers or fixed EC2 instances). The cluster is configured once via Route 53 and environment variables.

**Setup:**

1. **Create a Route 53 private hosted zone** (e.g., `joy.internal`) associated with your VPC.

2. **Add an A record for each node** pointing to its private IP:
   ```
   joy.internal  A  10.0.1.10   (node 1)
   joy.internal  A  10.0.1.11   (node 2)
   joy.internal  A  10.0.1.12   (node 3)
   ```
   Use a low TTL (10–30 seconds) so that when a node is removed, the other nodes stop trying to connect to it quickly.

3. **Set environment variables** on each node:
   ```sh
   DNS_CLUSTER_QUERY=joy.internal
   RELEASE_COOKIE=<same value on all nodes>
   ```

4. **Open firewall rules** (security group) between all nodes:
   - TCP `4369` — Erlang Port Mapper Daemon (epmd)
   - TCP `9100–9200` — Erlang distribution channel (pinned in `rel/vm.args.eex`)

5. **Start the app** on each node. When a node boots, it queries `joy.internal`, gets all peer IPs, and connects automatically.

**Deregistering a node:** Before taking a node offline, remove its A record from Route 53 first. This allows the remaining nodes to stop routing to it before it goes down. If you remove the record after the node is already down, the remaining nodes will briefly log connection errors until the TTL expires.

**Stable named nodes (homelab / florence.place):** If your servers have permanent, meaningful hostnames, see the commented-out `libcluster` block in `config/runtime.exs` for an alternative approach that gives you more readable node names (`joy@joy-1.florence.place` instead of `joy@10.0.1.10`).

---

### Amazon ECS

ECS with **Service Discovery** is the recommended production deployment. ECS automatically registers each task's IP in AWS Cloud Map, giving `dns_cluster` a DNS name that always reflects the live set of running tasks.

**Setup:**

1. **Create an ECS cluster** (EC2 or Fargate).

2. **Create a Cloud Map private DNS namespace** (e.g., `joy.local`).

3. **Create an ECS Service with Service Discovery enabled.** Choose the Cloud Map namespace. AWS will create a Cloud Map service and automatically register/deregister task IPs as tasks start and stop.
   - The resulting DNS name is typically `joy.joy.local` (service name `.` namespace) — check the Cloud Map console.

4. **Configure the task definition:**
   - Memory: at minimum 512MB; 1GB recommended for a comfortable margin
   - Port mappings: `4000` (HTTP), `4369` (epmd), `9100–9200` (distribution), plus any MLLP ports your channels use
   - All secrets (see [Environment Variables](#environment-variables)) pulled from Secrets Manager or SSM

5. **Set environment variables in the task definition:**
   ```
   DNS_CLUSTER_QUERY=joy.joy.local   (or whatever your Cloud Map DNS is)
   RELEASE_COOKIE=<from Secrets Manager>
   PHX_SERVER=true
   ```

6. **Security group rules** — same as bare metal: allow TCP `4369` and `9100–9200` between all task ENIs (source: the task security group itself).

7. **Run migrations as a one-off task** before the service starts:
   ```sh
   aws ecs run-task \
     --cluster joy \
     --task-definition joy-migrate \
     --overrides '{"containerOverrides": [{"name": "joy", "command": ["bin/migrate"]}]}'
   ```
   Or use an ECS service dependency / CodePipeline step to gate service start on a successful migration task.

**Fargate vs EC2 launch type:** Both work. Fargate simplifies operations (no EC2 instance management) at a higher cost per vCPU/memory. For this workload, Fargate is a reasonable choice.

**Load balancer:** Use an **Application Load Balancer (ALB)** for the web UI (port 4000). Use a **Network Load Balancer (NLB)** for MLLP ports (plain TCP). See [MLLP and Load Balancers](#mllp-and-load-balancers).

---

## Clustering

Joy uses [Horde](https://hexdocs.pm/horde/) for distributed process management and `dns_cluster` for node discovery. Here is what happens when a cluster boots:

1. Each node starts and queries `DNS_CLUSTER_QUERY` for A records.
2. It attempts to connect to every IP it finds as an Erlang node named `joy@<IP>`.
3. Once connected, `Horde.DynamicSupervisor` and `Horde.Registry` automatically sync their membership.
4. The `ChannelManager` on each node tries to start all `started: true` channels. Horde deduplicates: the first node to claim a channel runs it; subsequent nodes' attempts return `:already_started` and are ignored.
5. Channels run on exactly one node at a time. If that node dies, Horde restarts the channel's OTP tree on a surviving node within seconds.

**The `RELEASE_COOKIE` is critical.** Erlang silently rejects connection attempts from nodes with a different cookie. If two nodes share a database but have different cookies, they will never form a cluster and you will wonder why Horde isn't distributing channels.

**Detecting a split brain:** Erlang distribution uses TCP heartbeats (`net_ticktime`, set to 30 seconds in `rel/vm.args.eex`). If a node stops responding for `net_ticktime * 4 / 3` seconds (~40s), it is considered dead and Horde restarts its channels on surviving nodes. Reduce `net_ticktime` to detect failures faster at the cost of slightly more network traffic.

---

## MLLP and Load Balancers

MLLP is plain TCP. Each channel listens on its own port (configured per channel in the UI). When running a cluster, a given channel's MLLP port is only open on the one node currently running that channel.

**For a load balancer (NLB):**

Configure one target group per MLLP port. Enable **TCP health checks on that port**. The NLB will only route to nodes where the port is actually open (i.e., where that channel is running). When Horde moves a channel to a different node (e.g., after a node failure), the health check picks this up within one check interval and updates routing accordingly.

During the health check window (~10–30 seconds depending on your NLB settings), new TCP connections to that port will fail. Existing connections on the old node are broken by the node failure. **Upstream HL7 senders must handle TCP reconnects** — virtually all MLLP implementations do this, but it is worth verifying for any system sending into Joy.

**For environments without a load balancer (single node, small bare metal setups):** Upstream senders connect directly to the node IP. This is simpler but means if that node dies, senders need to reconnect to a different IP. This can be managed with DNS (a per-channel DNS A record that you update on failover), a floating IP, or by accepting that a short reconnect delay is acceptable given your upstream retry behavior.

**MLLP is not encrypted.** The MLLP protocol does not support TLS natively. HL7 messages sent over MLLP travel in plaintext. If the network path between your upstream system and Joy is not fully trusted (e.g., traverses the public internet or a shared network), use a VPN tunnel or an IPsec connection to encrypt the path. Within a private VPC/private network segment, plain MLLP is standard practice.

---

## Database

**Connection pool sizing:** Each node opens `POOL_SIZE` connections to the database. With 3 nodes at the default pool size of 10, you use 30 connections. PostgreSQL's default `max_connections` is 100. Adjust `POOL_SIZE` per node accordingly, or use PgBouncer if you need to run many nodes.

**Migrations:** The migration binary (`bin/migrate`) runs all pending migrations and exits. It is safe to run multiple times — already-applied migrations are skipped. Never run migrations in parallel from multiple nodes simultaneously.

**Backups:** The `message_log` table stores raw HL7 messages and contains PHI. Your backup strategy must cover this table with the same care as any PHI-containing system. Take regular snapshots of the Postgres database. If using RDS, enable automated backups and point-in-time recovery. Test restores regularly.

**Message log retention:** Joy does not currently enforce automatic log retention or purging. Plan a retention policy appropriate for your regulatory obligations and implement it as a scheduled database job (e.g., a cron job running `DELETE FROM message_log_entries WHERE inserted_at < NOW() - INTERVAL '90 days'` or similar). Consult your compliance requirements before setting the interval.

---

## Security

### PHI handling

The `message_log_entries` table stores raw inbound HL7 messages and the transformed output. These messages typically contain PHI (patient name, DOB, MRN, diagnosis codes, etc.).

- **Encryption at rest:** Enable full-disk or tablespace encryption on your Postgres server. On RDS, enable storage encryption at creation time (it cannot be added later). This protects data if storage media is ever physically accessed.
- **Network encryption:** Enable `ssl: true` in `config/runtime.exs` for the database connection. Uncomment and configure the `ssl:` option in the Ecto repo config block.
- **Log retention:** Do not retain messages longer than necessary. Implement a retention policy (see [Database](#database)).
- **Access control:** Only grant database access to the Joy application user. Do not share the `DATABASE_URL` or allow direct DB access from outside the private network.

### The `ENCRYPTION_KEY`

This key encrypts destination credentials (API keys, MLLP passwords, webhook secrets, etc.) stored in the `destination_configs` table. It does **not** encrypt HL7 message content in the message log.

- Generate with: `iex -e ":crypto.strong_rand_bytes(32) |> Base.encode64() |> IO.puts"`
- Store in Secrets Manager or SSM Parameter Store — never in code or a committed `.env` file.
- **If this key is lost, all destination credentials are unrecoverable.** Back it up securely.
- **If this key is rotated,** all stored destination credentials will fail to decrypt. There is currently no key rotation tooling — this is a known gap.

### Web UI

- All routes require authentication. Users must be explicitly promoted to admin (`mix joy.make_admin`) before accessing anything. Self-registered users cannot see the application.
- Use HTTPS. Configure a reverse proxy (nginx, ALB) to terminate TLS and proxy to Joy's port 4000. See the commented `https:` block in `config/runtime.exs` for terminating TLS directly in Joy if preferred.
- Set `PHX_HOST` to your actual hostname to prevent host header injection.

### Firewall / security group rules

| Port | Protocol | Direction | Purpose |
|---|---|---|---|
| `4000` | TCP | Inbound from your users/reverse proxy | Web UI and API |
| Your MLLP ports | TCP | Inbound from upstream HL7 senders | MLLP ingress |
| `4369` | TCP | Inbound from other Joy nodes only | Erlang epmd |
| `9100–9200` | TCP | Inbound from other Joy nodes only | Erlang distribution |
| `5432` | TCP | Outbound to Postgres | Database |

Do **not** expose ports `4369` and `9100–9200` to the public internet or to machines that are not Joy nodes. Erlang distribution provides no authentication beyond the shared cookie, and the cookie is not designed to be a public-facing secret.

---

## Upgrading

Joy upgrades are rolling-compatible: new nodes can run alongside old nodes as long as the schema migration is backward compatible (i.e., does not drop or rename columns the old code reads).

**Recommended rolling upgrade procedure:**

1. Build and push the new image.
2. Run `bin/migrate` from the new version against the database. (Old nodes handle old schema; new schema additions are additive and ignored by old code.)
3. Replace nodes one at a time. When a node is taken out of the cluster, Horde redistributes its channels to the remaining nodes within seconds.
4. Wait for each new node to join the cluster and Horde to confirm membership before replacing the next one.

**Zero-downtime MLLP:** Channel continuity during a rolling upgrade depends on the upstream sender's reconnect behavior. When a node running a channel is replaced, that channel briefly goes down (~5–30 seconds) and then comes back on a surviving or newly started node. Senders with reconnect logic (standard in MLLP implementations) will reconnect automatically. If zero-downtime MLLP is critical, you can pin channels to specific nodes and upgrade the non-pinned nodes first, though Joy does not currently have a built-in channel-pinning feature.

---

## Day-Two Operations

### Checking cluster membership

From a running node's remote shell:

```sh
bin/joy rpc "Node.list()"
# => [:"joy@10.0.1.11", :"joy@10.0.1.12"]

bin/joy rpc "Horde.Cluster.members(Joy.ChannelSupervisor)"
# => lists all Horde members and their node
```

### Checking which node is running a channel

```sh
bin/joy rpc "Horde.Registry.lookup(Joy.ChannelRegistry, 1)"
# => [{#PID<x.y.z>, nil}]  — PID tells you the node via Node.node(pid)
```

### Manually restarting a channel

From the web UI: use the Start/Stop controls on the channel page. From the console:

```sh
bin/joy rpc "Joy.ChannelManager.stop_channel(1)"
bin/joy rpc "Joy.ChannelManager.start_channel(1)"
```

### Forcing a migration retry

If a message is stuck in `pending` status (e.g., because a destination was down and the pipeline crashed mid-delivery), it will be requeued automatically when the channel's Pipeline restarts. You can force a restart by stopping and starting the channel from the UI. The pipeline requeues all `pending` entries for its channel on `init`.

### Admin user management

```sh
# Promote a user to admin
bin/joy eval "Mix.Tasks.Joy.MakeAdmin.run([\"user@example.com\"])"

# Demote (via IEx remote shell)
bin/joy rpc "Joy.Accounts.get_user_by_email!(\"user@example.com\") |> Ecto.Changeset.change(%{is_admin: false}) |> Joy.Repo.update!()"
```
