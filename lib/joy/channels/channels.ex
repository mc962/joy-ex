defmodule Joy.Channels do
  @moduledoc """
  Public context for channel, transform step, and destination config CRUD.

  Runtime lifecycle (start/stop) is handled by Joy.ChannelManager — this context
  only manages persisted DB state. The separation keeps concerns clean.

  # GO-TRANSLATION:
  # Repository/service layer pattern. Phoenix contexts serve the same purpose
  # with simpler boilerplate (no interface definitions needed for internal use).
  """

  import Ecto.Query
  alias Joy.{Repo, Channels.Channel, Channels.TransformStep, Channels.DestinationConfig}

  @preload_query [transform_steps: from(t in TransformStep, order_by: [asc: t.position]),
                  destination_configs: from(d in DestinationConfig, order_by: [asc: d.id])]

  # --- Channels ---

  @doc "List all channels with preloaded associations, ordered by name."
  def list_channels do
    Channel
    |> order_by([c], asc: c.name)
    |> Repo.all()
    |> Repo.preload(@preload_query)
  end

  @doc "List channels with started: true (to auto-start on boot)."
  def list_started_channels do
    Channel
    |> where([c], c.started == true)
    |> Repo.all()
    |> Repo.preload(@preload_query)
  end

  @doc "Get a channel by id with preloads. Raises if not found."
  def get_channel!(id) do
    Channel
    |> Repo.get!(id)
    |> Repo.preload(@preload_query)
  end

  @doc "Create a channel. Returns {:ok, channel} or {:error, changeset}."
  def create_channel(attrs) do
    %Channel{}
    |> Channel.changeset(attrs)
    |> Repo.insert()
    |> tap_ok(&broadcast("channel_created", &1))
  end

  @doc "Update a channel."
  def update_channel(%Channel{} = channel, attrs) do
    channel
    |> Channel.changeset(attrs)
    |> Repo.update()
    |> tap_ok(&broadcast("channel_updated", &1))
  end

  @doc "Delete a channel (cascades to transform_steps and destination_configs)."
  def delete_channel(%Channel{} = channel) do
    Repo.delete(channel)
    |> tap_ok(&broadcast("channel_deleted", &1))
  end

  @doc "Set the started flag (user intent). Does not actually start/stop the OTP tree."
  def set_started(%Channel{} = channel, started) when is_boolean(started) do
    channel
    |> Channel.changeset(%{started: started})
    |> Repo.update()
    |> tap_ok(&broadcast("channel_updated", &1))
  end

  # --- Transform Steps ---

  @doc "Create or update a transform step. Pass id in attrs to update."
  def upsert_transform_step(channel_id, attrs) do
    attrs = Map.merge(stringify_keys(attrs), %{"channel_id" => channel_id})

    case Map.get(attrs, "id") do
      nil ->
        %TransformStep{}
        |> TransformStep.changeset(attrs)
        |> Repo.insert()

      id ->
        TransformStep
        |> Repo.get!(id)
        |> TransformStep.changeset(attrs)
        |> Repo.update()
    end
    |> tap_ok(fn _ -> broadcast("channel_updated", get_channel!(channel_id)) end)
  end

  @doc "Delete a transform step."
  def delete_transform_step(%TransformStep{} = step) do
    Repo.delete(step)
    |> tap_ok(fn _ -> broadcast("channel_updated", get_channel!(step.channel_id)) end)
  end

  @doc "Reorder transform steps. ordered_ids is a list of step IDs in desired order."
  def reorder_transform_steps(channel_id, ordered_ids) do
    Repo.transaction(fn ->
      ordered_ids
      |> Enum.with_index()
      |> Enum.each(fn {id, position} ->
        from(t in TransformStep, where: t.id == ^id and t.channel_id == ^channel_id)
        |> Repo.update_all(set: [position: position])
      end)
    end)
    |> tap_ok(fn _ -> broadcast("channel_updated", get_channel!(channel_id)) end)
  end

  # --- Destination Configs ---

  @doc "Create or update a destination config."
  def upsert_destination_config(channel_id, attrs) do
    attrs = Map.merge(stringify_keys(attrs), %{"channel_id" => channel_id})

    case Map.get(attrs, "id") do
      nil ->
        %DestinationConfig{}
        |> DestinationConfig.changeset(attrs)
        |> Repo.insert()

      id ->
        DestinationConfig
        |> Repo.get!(id)
        |> DestinationConfig.changeset(attrs)
        |> Repo.update()
    end
    |> tap_ok(fn _ -> broadcast("channel_updated", get_channel!(channel_id)) end)
  end

  @doc "Delete a destination config."
  def delete_destination_config(%DestinationConfig{} = dest) do
    Repo.delete(dest)
    |> tap_ok(fn _ -> broadcast("channel_updated", get_channel!(dest.channel_id)) end)
  end

  # --- Helpers ---

  defp broadcast(event, payload) do
    Phoenix.PubSub.broadcast(Joy.PubSub, "channels", {String.to_atom(event), payload})
  end

  defp tap_ok({:ok, val} = result, fun), do: (fun.(val); result)
  defp tap_ok(result, _fun), do: result

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  defp stringify_keys(other), do: other
end
