defmodule Joy.Accounts.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The `Joy.Accounts.Scope` allows public interfaces to receive
  information about the caller, such as if the call is initiated from an
  end-user, and if so, which user. Additionally, such a scope can carry fields
  such as "super user" or other privileges for use as authorization, or to
  ensure specific code paths can only be access for a given scope.

  It is useful for logging as well as for scoping pubsub subscriptions and
  broadcasts when a caller subscribes to an interface or performs a particular
  action.

  Feel free to extend the fields on this struct to fit the needs of
  growing application requirements.
  """

  alias Joy.Accounts.User

  defstruct [:user, :service_account]

  @doc "Creates a scope for the given user. Returns nil if no user is given."
  def for_user(%User{} = user), do: %__MODULE__{user: user}
  def for_user(nil), do: nil

  @doc "Creates a scope for a service account."
  def for_service_account(sa), do: %__MODULE__{service_account: sa}

  @doc "Returns true only for human users with is_admin set."
  def admin?(%__MODULE__{user: %{is_admin: true}}), do: true
  def admin?(_), do: false

  @doc """
  Returns the organization_id to filter queries by, or nil for unscoped access.

  Admins see everything (nil). Users with no org see everything (nil, preserves
  single-tenant behaviour). Users with an org see only their org's resources.
  Service accounts have no org and see everything.
  """
  def org_id(%__MODULE__{user: %{is_admin: true}}), do: nil
  def org_id(%__MODULE__{user: %{organization_id: id}}), do: id
  def org_id(_), do: nil
end
