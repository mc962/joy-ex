import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/joy start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :joy, JoyWeb.Endpoint, server: true
end

# Encryption key for destination credentials (AES-256-GCM).
# Generate a 32-byte key with: :crypto.strong_rand_bytes(32) |> Base.encode64()
# Must be set in all environments. Dev uses a fixed dummy key in dev.exs.
if System.get_env("ENCRYPTION_KEY") do
  config :joy, :encryption_key, System.get_env("ENCRYPTION_KEY")
end

if System.get_env("ENCRYPTION_KEY_OLD") do
  config :joy, :encryption_key_old, System.get_env("ENCRYPTION_KEY_OLD")
end

config :joy, JoyWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :joy, Joy.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  if replica_url = System.get_env("REPLICA_DATABASE_URL") do
    config :joy, Joy.Repo.Replica,
      url: replica_url,
      pool_size: String.to_integer(System.get_env("REPLICA_POOL_SIZE") || System.get_env("POOL_SIZE") || "10"),
      socket_options: maybe_ipv6

    config :joy, :replica_enabled, true
  end

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :joy, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Stable bare-metal / homelab alternative: named nodes with libcluster Epmd.
  # Use this instead of dns_cluster when your nodes have fixed identities and
  # hostnames (e.g. dedicated servers or static EC2s with Route 53 records).
  # Node names are human-readable in logs and `iex --remsh` is nicer to type.
  #
  # Steps to switch:
  #   1. Add `{:libcluster, "~> 3.3"}` to mix.exs deps
  #   2. Remove the DNSCluster child from application.ex (or leave it — it's harmless)
  #   3. Add `{Cluster.Supervisor, [topologies, [name: Joy.ClusterSupervisor]]}` to application.ex
  #   4. Set RELEASE_NODE in rel/env.sh.eex to a fixed name instead of the IP-based one, e.g.:
  #        export RELEASE_NODE="joy@$(hostname -f)"   # uses the machine's FQDN
  #
  # Example for a 3-node homelab cluster at example.com:
  #
  # topologies = [
  #   joy: [
  #     strategy: Cluster.Strategy.Epmd,
  #     config: [
  #       hosts: [
  #         :"joy@joy-1.example.com",
  #         :"joy@joy-2.example.com,
  #         :"joy@joy-3.example.com"
  #       ]
  #     ]
  #   ]
  # ]
  # config :libcluster, topologies: topologies

  config :joy, JoyWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    # Allowed WebSocket origins. Defaults to just PHX_HOST. Set CHECK_ORIGINS
    # to a comma-separated list to also allow per-node subdomains for debugging,
    # e.g. "https://joy.example.com,https://joy-1.example.com,https://joy-2.example.com"
    check_origin: System.get_env("CHECK_ORIGINS", "https://#{host}")
                  |> String.split(",")
                  |> Enum.map(&String.trim/1),
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :joy, JoyWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :joy, JoyWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  smtp_host = System.get_env("SMTP_HOST") || raise("SMTP_HOST is missing")

  config :joy, Joy.Mailer,
    adapter: Swoosh.Adapters.SMTP,
    relay: smtp_host,
    port: String.to_integer(System.get_env("SMTP_PORT", "587")),
    username: System.get_env("SMTP_USER") || raise("SMTP_USER is missing"),
    password: System.get_env("SMTP_PASSWORD") || raise("SMTP_PASSWORD is missing"),
    tls: :always,
    auth: :always,
    hostname: System.get_env("SMTP_HOSTNAME", "localhost"),
    tls_options: [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(smtp_host),
      depth: 4
    ]
end
