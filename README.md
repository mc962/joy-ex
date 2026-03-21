# Joy

Joy is a self-hosted HL7 v2.x integration engine built on Elixir/OTP. It receives HL7 messages over MLLP (TCP), applies user-defined transforms, and forwards them to destinations (HTTP webhooks, AWS SNS/SQS, MLLP forward, Redis, or file).

It is designed for production healthcare environments: at-least-once delivery, full message audit log, AES-256-GCM encrypted destination credentials, and multi-node HA clustering via [Horde](https://hexdocs.pm/horde/).

## Quick start (development)

```sh
mix setup          # installs deps, creates and migrates DB, builds assets
mix phx.server     # start the dev server at http://localhost:4000
```

Register a user at `/users/register`, then promote them to admin:

```sh
mix joy.make_admin your@email.com
```

## Documentation

- **[Deployment guide](docs/deployment.md)** — Docker, bare metal/EC2, ECS, clustering, security, PHI handling, upgrading
- **[Architecture overview](docs/architecture.md)** — channel model, message flow, OTP tree, transforms, destinations, clustering
- **[Design notes](docs/design.md)** — implementation decisions, trade-offs, edge cases, known gaps

## Stack

- **Elixir / Phoenix / OTP** — per-channel isolated supervisor trees, at-least-once delivery
- **PostgreSQL** — channels, transforms, destinations, message log, user accounts
- **Horde** — distributed process registry and supervisor for multi-node HA
- **MLLP** — custom TCP server and framer (no external MLLP library dependency)
