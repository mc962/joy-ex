defmodule Joy.ServiceAccounts do
  @moduledoc "Service account management: create, rotate, delete, and verify machine-actor tokens."

  import Ecto.Query
  alias Joy.Repo
  alias Joy.ServiceAccounts.{ServiceAccount, ServiceAccountToken}

  @doc "List all service accounts with their active token preloaded."
  def list_service_accounts do
    Repo.all(from sa in ServiceAccount, order_by: [asc: sa.inserted_at], preload: [:token])
  end

  @doc """
  Create a new service account with an initial token.
  Returns `{:ok, {plain_token, service_account}}`.
  """
  def create_service_account(name) do
    now = DateTime.utc_now(:second)

    Repo.transaction(fn ->
      sa =
        %ServiceAccount{}
        |> ServiceAccount.changeset(%{name: name, inserted_at: now})
        |> Repo.insert!()

      {plain, token} = insert_token(sa.id, now)
      sa = %{sa | token: token}
      {plain, sa}
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, _} = err -> err
    end
  end

  @doc """
  Replace the active token for a service account.
  Returns `{:ok, plain_token}`.
  """
  def rotate_token(%ServiceAccount{} = sa) do
    now = DateTime.utc_now(:second)

    Repo.transaction(fn ->
      Repo.delete_all(from t in ServiceAccountToken, where: t.service_account_id == ^sa.id)
      {plain, _token} = insert_token(sa.id, now)
      plain
    end)
    |> case do
      {:ok, plain} -> {:ok, plain}
      {:error, _} = err -> err
    end
  end

  @doc "Delete a service account by id (cascades to its token)."
  def delete_service_account(id) do
    case Repo.get(ServiceAccount, id) do
      nil -> {:error, :not_found}
      sa  -> Repo.delete(sa)
    end
  end

  @doc "Verify a plain service account token. Returns `{:ok, token_id, service_account}` or `{:error, :not_found}`."
  def verify_token(plain) do
    hash = hash_token(plain)

    query =
      from t in ServiceAccountToken,
        where: t.token_hash == ^hash,
        preload: [:service_account]

    case Repo.one(query) do
      nil   -> {:error, :not_found}
      token -> {:ok, token.id, token.service_account}
    end
  end

  @doc "Update last_used_at for a service account token. Call asynchronously."
  def touch_last_used(token_id) do
    now = DateTime.utc_now(:second)
    Repo.update_all(from(t in ServiceAccountToken, where: t.id == ^token_id), set: [last_used_at: now])
  end

  defp insert_token(service_account_id, now) do
    plain = "joy_svc_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    hash  = hash_token(plain)

    token =
      %ServiceAccountToken{}
      |> ServiceAccountToken.changeset(%{
        service_account_id: service_account_id,
        token_hash:         hash,
        inserted_at:        now
      })
      |> Repo.insert!()

    {plain, token}
  end

  defp hash_token(plain) do
    :crypto.hash(:sha256, plain) |> Base.encode16(case: :lower)
  end
end
