defmodule Joy.ServiceAccounts.ServiceAccount do
  use Ecto.Schema
  import Ecto.Changeset

  schema "service_accounts" do
    field :name,        :string
    field :inserted_at, :utc_datetime, autogenerate: false
    has_one :token, Joy.ServiceAccounts.ServiceAccountToken
  end

  def changeset(sa, attrs) do
    sa
    |> cast(attrs, [:name, :inserted_at])
    |> validate_required([:name, :inserted_at])
    |> validate_length(:name, min: 1, max: 255)
  end
end
