defmodule Mix.Tasks.Joy.MakeAdmin do
  @shortdoc "Grants admin privileges to a user by email"
  @moduledoc """
  Usage: mix joy.make_admin user@example.com

  Sets is_admin = true on the given user. The user must already exist.
  """

  use Mix.Task

  @requirements ["app.start"]

  def run([email]) do
    case Joy.Repo.get_by(Joy.Accounts.User, email: email) do
      nil ->
        Mix.shell().error("No user found with email: #{email}")

      user ->
        user
        |> Ecto.Changeset.change(is_admin: true)
        |> Joy.Repo.update!()

        Mix.shell().info("#{email} is now an admin.")
    end
  end

  def run(_), do: Mix.shell().error("Usage: mix joy.make_admin <email>")
end
