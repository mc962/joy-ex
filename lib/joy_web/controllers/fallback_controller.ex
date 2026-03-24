defmodule JoyWeb.FallbackController do
  use JoyWeb, :controller

  def call(conn, {:error, %Ecto.Changeset{} = cs}) do
    errors =
      Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: errors})
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{errors: %{detail: "Not found"}})
  end

  def call(conn, {:error, :unauthorized}) do
    conn
    |> put_status(:forbidden)
    |> json(%{errors: %{detail: "Admin access required"}})
  end

  def call(conn, {:error, :invalid_credentials}) do
    conn
    |> put_status(:unauthorized)
    |> json(%{errors: %{detail: "Invalid email or password"}})
  end

  def call(conn, {:error, :token_limit_reached}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{detail: "Token limit reached (10 max). Revoke an existing token first."}})
  end
end
