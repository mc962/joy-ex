defmodule Joy.Sinks do
  @moduledoc """
  In-memory message sink for testing destinations.

  Maintains a capped ring buffer per named sink. Messages are stored in memory
  only — restarts clear all sinks, which is intentional for a test tool.

  Each entry: %{id, received_at, raw, msg_type, control_id, sending_app}

  PubSub topic "sinks" carries:
    {:sink_message, sink_name, entry}  — new message arrived
    {:sink_cleared, sink_name}         — sink was manually cleared

  # GO-TRANSLATION:
  # sync.RWMutex-protected map[string][]Entry. Elixir GenServer serialises all
  # writes; reads can go direct to the process mailbox via call.
  """

  use GenServer
  require Logger

  @max_messages 200

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc "Push a parsed HL7 message into the named sink."
  @spec push(String.t(), Joy.HL7.Message.t()) :: :ok
  def push(name, msg) do
    GenServer.cast(__MODULE__, {:push, name, msg})
  end

  @doc "List all sink names that have received at least one message."
  @spec list_sinks() :: [String.t()]
  def list_sinks do
    GenServer.call(__MODULE__, :list_sinks)
  end

  @doc "Get all messages for a named sink, newest first."
  @spec get_messages(String.t()) :: [map()]
  def get_messages(name) do
    GenServer.call(__MODULE__, {:get_messages, name})
  end

  @doc "Return the full state as a map of name => messages for initial LiveView mount."
  @spec all() :: %{String.t() => [map()]}
  def all do
    GenServer.call(__MODULE__, :all)
  end

  @doc "Clear all messages from a named sink."
  @spec clear(String.t()) :: :ok
  def clear(name) do
    GenServer.cast(__MODULE__, {:clear, name})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(state) do
    Phoenix.PubSub.subscribe(Joy.PubSub, "sinks")
    {:ok, state}
  end

  @impl true
  def handle_cast({:push, name, msg}, state) do
    raw = Joy.HL7.to_string(msg)
    entry = %{
      id: System.unique_integer([:positive, :monotonic]),
      received_at: DateTime.utc_now(),
      raw: raw,
      msg_type: Joy.HL7.get(msg, "MSH.9") || "unknown",
      control_id: Joy.HL7.get(msg, "MSH.10") || "—",
      sending_app: Joy.HL7.get(msg, "MSH.3") || "—"
    }

    existing = Map.get(state, name, [])
    updated = Enum.take([entry | existing], @max_messages)
    new_state = Map.put(state, name, updated)

    Phoenix.PubSub.broadcast_from(Joy.PubSub, self(), "sinks", {:sink_message, name, entry})
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:clear, name}, state) do
    new_state = Map.put(state, name, [])
    Phoenix.PubSub.broadcast_from(Joy.PubSub, self(), "sinks", {:sink_cleared, name})
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:list_sinks, _from, state) do
    {:reply, Map.keys(state) |> Enum.sort(), state}
  end

  @impl true
  def handle_call({:get_messages, name}, _from, state) do
    {:reply, Map.get(state, name, []), state}
  end

  @impl true
  def handle_call(:all, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info({:sink_message, name, entry}, state) do
    existing = Map.get(state, name, [])
    updated = Enum.take([entry | existing], @max_messages)
    {:noreply, Map.put(state, name, updated)}
  end

  @impl true
  def handle_info({:sink_cleared, name}, state) do
    {:noreply, Map.put(state, name, [])}
  end
end
