defmodule Joy.ApiTokens do
  @moduledoc "API token management: create, list, revoke, and verify Bearer tokens."

  import Ecto.Query
  alias Joy.Repo
  alias Joy.ApiTokens.ApiToken

  @token_limit 10
  @default_ttl_days 90
  @max_ttl_days 90

  @doc """
  Generate a new token for the user. Returns `{:ok, {plain_token, token_record}}`.
  The plain token is shown once and never stored — only the SHA-256 hash is persisted.

  Expired tokens are cleaned up first, then the active count is checked against the
  #{@token_limit}-token per-user limit. Returns `{:error, :token_limit_reached}` if full.

  Accepts `ttl_days` in attrs (1–365). Defaults to #{@default_ttl_days} days.
  """
  def create_token(user, attrs) do
    ttl_days   = parse_ttl(attrs["ttl_days"] || attrs[:ttl_days])
    now        = DateTime.utc_now(:second)
    expires_at = DateTime.add(now, ttl_days * 86_400, :second)

    Repo.delete_all(from t in ApiToken,
      where: t.user_id == ^user.id and t.expires_at <= ^now)

    count = Repo.aggregate(from(t in ApiToken, where: t.user_id == ^user.id), :count)

    if count >= @token_limit do
      {:error, :token_limit_reached}
    else
      plain = "joy_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      hash  = hash_token(plain)

      result =
        %ApiToken{}
        |> ApiToken.changeset(%{
          user_id:     user.id,
          name:        attrs["name"] || attrs[:name] || "Unnamed",
          token_hash:  hash,
          expires_at:  expires_at,
          inserted_at: now
        })
        |> Repo.insert()

      case result do
        {:ok, token} -> {:ok, {plain, token}}
        {:error, cs} -> {:error, cs}
      end
    end
  end

  @doc "List all active (non-expired) tokens for a user, newest first."
  def list_tokens(user) do
    now = DateTime.utc_now(:second)

    ApiToken
    |> where([t], t.user_id == ^user.id and t.expires_at > ^now)
    |> order_by([t], desc: t.inserted_at)
    |> Repo.all()
  end

  @doc "Delete a token by id, verifying it belongs to the user."
  def revoke_token(user, id) do
    case Repo.get_by(ApiToken, id: id, user_id: user.id) do
      nil   -> {:error, :not_found}
      token -> Repo.delete(token)
    end
  end

  @doc "Verify a plain token. Returns `{:ok, token_id, user}` or `{:error, :not_found}`."
  def verify_token(plain) do
    hash = hash_token(plain)
    now  = DateTime.utc_now(:second)

    query = from t in ApiToken,
      where: t.token_hash == ^hash and t.expires_at > ^now,
      preload: [:user]

    case Repo.one(query) do
      nil   -> {:error, :not_found}
      token -> {:ok, token.id, token.user}
    end
  end

  @doc "Update last_used_at for a token. Call asynchronously to avoid blocking requests."
  def touch_last_used(token_id) do
    now = DateTime.utc_now(:second)
    Repo.update_all(from(t in ApiToken, where: t.id == ^token_id), set: [last_used_at: now])
  end

  defp hash_token(plain) do
    :crypto.hash(:sha256, plain) |> Base.encode16(case: :lower)
  end

  defp parse_ttl(n) when is_integer(n) and n >= 1 and n <= @max_ttl_days, do: n
  defp parse_ttl(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 1 and n <= @max_ttl_days -> n
      _ -> @default_ttl_days
    end
  end
  defp parse_ttl(_), do: @default_ttl_days
end
