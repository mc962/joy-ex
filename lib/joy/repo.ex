defmodule Joy.Repo do
  use Ecto.Repo,
    otp_app: :joy,
    adapter: Ecto.Adapters.Postgres

  @doc "Returns Joy.Repo.Replica when a replica is configured, otherwise Joy.Repo (primary)."
  def replica do
    if Application.get_env(:joy, :replica_enabled),
      do: Joy.Repo.Replica,
      else: __MODULE__
  end
end
