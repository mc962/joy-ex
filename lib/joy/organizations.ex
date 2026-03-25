defmodule Joy.Organizations do
  @moduledoc """
  Public context for organization CRUD.

  Organizations group channels by health system. They hold shared config
  (IP allowlist, alert contacts, TLS CA cert) that flows down to member channels
  as fallbacks in Joy.Channels.effective_allowed_ips/1 and Joy.Alerting.

  # GO-TRANSLATION:
  # Repository/service layer pattern. Phoenix contexts serve the same purpose
  # with simpler boilerplate.
  """

  import Ecto.Query
  alias Joy.{Repo, Organizations.Organization}
  alias Joy.Accounts.Scope

  @doc "List organizations ordered by name. Pass a scope to restrict to the user's org."
  def list_organizations(scope \\ nil) do
    Organization
    |> apply_org_filter(scope)
    |> order_by([o], asc: o.name)
    |> Repo.all()
  end

  @doc "Get an organization by id. Raises if not found or outside scope."
  def get_organization!(id, scope \\ nil) do
    Organization
    |> where([o], o.id == ^id)
    |> apply_org_filter(scope)
    |> Repo.one!()
  end

  @doc "Create an organization. Returns {:ok, org} or {:error, changeset}."
  def create_organization(attrs) do
    %Organization{}
    |> Organization.changeset(attrs)
    |> Repo.insert()
    |> tap_ok(&broadcast("org_created", &1))
  end

  @doc "Update an organization."
  def update_organization(%Organization{} = org, attrs) do
    org
    |> Organization.changeset(attrs)
    |> Repo.update()
    |> tap_ok(&broadcast("org_updated", &1))
  end

  @doc "Delete an organization. Channels and users are nilified (not deleted)."
  def delete_organization(%Organization{} = org) do
    Repo.delete(org)
    |> tap_ok(&broadcast("org_deleted", &1))
  end

  @doc "Return a changeset for UI forms."
  def change_organization(%Organization{} = org, attrs \\ %{}) do
    Organization.changeset(org, attrs)
  end

  # --- Helpers ---

  defp apply_org_filter(query, scope) do
    case scope && Scope.org_id(scope) do
      nil    -> query
      org_id -> where(query, [o], o.id == ^org_id)
    end
  end

  defp broadcast(event, payload) do
    Phoenix.PubSub.broadcast(Joy.PubSub, "organizations", {String.to_atom(event), payload})
  end

  defp tap_ok({:ok, val} = result, fun), do: (fun.(val); result)
  defp tap_ok(result, _fun), do: result
end
