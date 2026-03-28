defmodule Joy.Repo.Replica do
  use Ecto.Repo,
    otp_app: :joy,
    adapter: Ecto.Adapters.Postgres,
    read_only: true
end
