defmodule Joy.AuditLog.Entry do
  use Ecto.Schema
  import Ecto.Changeset

  schema "audit_log_entries" do
    belongs_to :actor, Joy.Accounts.User
    field :actor_email,   :string
    field :action,        :string
    field :resource_type, :string
    field :resource_id,   :integer
    field :resource_name, :string
    field :changes,       :map
    field :inserted_at,   :utc_datetime, autogenerate: false
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:actor_id, :actor_email, :action, :resource_type,
                    :resource_id, :resource_name, :changes, :inserted_at])
    |> validate_required([:action, :resource_type, :inserted_at])
  end
end
