defmodule Joy.ServiceAccounts.ServiceAccountToken do
  use Ecto.Schema
  import Ecto.Changeset

  schema "service_account_tokens" do
    belongs_to :service_account, Joy.ServiceAccounts.ServiceAccount
    field :token_hash,   :string
    field :last_used_at, :utc_datetime
    field :inserted_at,  :utc_datetime, autogenerate: false
  end

  def changeset(token, attrs) do
    token
    |> cast(attrs, [:service_account_id, :token_hash, :inserted_at])
    |> validate_required([:service_account_id, :token_hash, :inserted_at])
  end
end
