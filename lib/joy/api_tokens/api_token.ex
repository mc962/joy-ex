defmodule Joy.ApiTokens.ApiToken do
  use Ecto.Schema
  import Ecto.Changeset

  schema "api_tokens" do
    belongs_to :user, Joy.Accounts.User
    field :name,         :string
    field :token_hash,   :string
    field :last_used_at, :utc_datetime
    field :expires_at,   :utc_datetime
    field :inserted_at,  :utc_datetime, autogenerate: false
  end

  def changeset(token, attrs) do
    token
    |> cast(attrs, [:user_id, :name, :token_hash, :expires_at, :inserted_at])
    |> validate_required([:user_id, :name, :token_hash, :expires_at, :inserted_at])
    |> validate_length(:name, min: 1, max: 100)
    |> unique_constraint(:token_hash)
  end
end
