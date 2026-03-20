defmodule Joy.Repo do
  use Ecto.Repo,
    otp_app: :joy,
    adapter: Ecto.Adapters.Postgres
end
