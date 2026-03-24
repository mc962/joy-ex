defmodule Joy.AuditLog do
  @moduledoc """
  Immutable audit trail for all admin-gated mutations.

  Entries record who did what to which resource. Sensitive values (TLS keys,
  destination credentials) are never stored — only non-secret metadata like
  field names, booleans, and IDs.

  # GO-TRANSLATION:
  # Direct equivalent: an append-only DB table with an insert helper.
  # In Go this would be an AuditService with a Log(ctx, entry) method, where
  # ctx carries the authenticated user identity.
  """

  import Ecto.Query
  alias Joy.Repo
  alias Joy.AuditLog.Entry

  @doc """
  Write an audit entry. `user` may be nil for system/CLI operations.
  `changes` must never contain secrets (keys, passwords, tokens).
  """
  def log(user, action, resource_type, resource_id, resource_name, changes \\ %{}) do
    %Entry{}
    |> Entry.changeset(%{
      actor_id:      user && user.id,
      actor_email:   user && user.email,
      action:        action,
      resource_type: resource_type,
      resource_id:   resource_id,
      resource_name: resource_name,
      changes:       changes,
      inserted_at:   DateTime.utc_now(:second)
    })
    |> Repo.insert()
  end

  @doc """
  List audit entries newest-first.

  Options:
    - `:resource_type` — filter to a specific resource type string
    - `:actor_id` — filter to a specific user id
    - `:from` — `DateTime` lower bound (inclusive)
    - `:to` — `DateTime` upper bound (inclusive)
    - `:limit` — max rows (default 100)
  """
  def list_entries(opts \\ []) do
    Entry
    |> maybe_filter(:resource_type, opts[:resource_type])
    |> maybe_filter(:actor_id, opts[:actor_id])
    |> maybe_from(opts[:from])
    |> maybe_to(opts[:to])
    |> order_by([e], desc: e.inserted_at)
    |> limit(^(opts[:limit] || 100))
    |> Repo.all()
  end

  @doc "Total audit entry count."
  def count_total do
    Repo.aggregate(Entry, :count, :id)
  end

  @doc "Count entries older than `days` days. Returns 0 if days is nil."
  def count_purgeable(nil), do: 0
  def count_purgeable(days) do
    Repo.aggregate(purgeable_query(days), :count, :id)
  end

  @doc "Timestamp of the oldest audit entry, or nil."
  def oldest_entry_date do
    Repo.one(from e in Entry, select: min(e.inserted_at))
  end

  @doc """
  Delete audit entries older than `days` days.
  Returns the number of entries deleted.
  """
  def purge_old(days) when days > 0 do
    {count, _} = Repo.delete_all(purgeable_query(days))
    count
  end

  defp purgeable_query(days) do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
    from e in Entry, where: e.inserted_at < ^cutoff
  end

  defp maybe_filter(q, _field, nil),   do: q
  defp maybe_filter(q, _field, ""),    do: q
  defp maybe_filter(q, field, value),  do: where(q, [e], field(e, ^field) == ^value)

  defp maybe_from(q, nil), do: q
  defp maybe_from(q, dt),  do: where(q, [e], e.inserted_at >= ^dt)

  defp maybe_to(q, nil), do: q
  defp maybe_to(q, dt),  do: where(q, [e], e.inserted_at <= ^dt)
end
