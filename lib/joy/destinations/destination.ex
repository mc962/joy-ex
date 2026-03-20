defmodule Joy.Destinations.Destination do
  @moduledoc """
  Behaviour defining the interface all destination adapters must implement.

  Generic by design: deliver/2 takes a message + config map. Any backend
  (queue, broker, HTTP, file) can be supported by implementing two callbacks.

  Adding a new adapter requires only:
    1. Create a module implementing this behaviour
    2. Add it to adapter_module/1 below
    3. Add adapter-specific config fields to the LiveView form
  No changes to channel pipeline logic are needed.

  # GO-TRANSLATION:
  # type Destination interface {
  #   Deliver(msg Message, config map[string]any) error
  #   ValidateConfig(config map[string]any) error
  #   AdapterName() string
  # }
  # Elixir behaviours are structurally identical to Go interfaces.
  # The main difference: Elixir dispatches via the module atom at runtime.
  """

  @doc "Deliver a message to the destination. Returns :ok or {:error, human-readable reason}."
  @callback deliver(message :: Joy.HL7.Message.t(), config :: map()) ::
              :ok | {:error, String.t()}

  @doc "Validate a config map before saving. Returns :ok or {:error, reason}."
  @callback validate_config(config :: map()) :: :ok | {:error, String.t()}

  @doc "The string identifier for this adapter, stored in destination_configs.adapter."
  @callback adapter_name() :: String.t()

  @doc "Returns the list of all valid adapter name strings."
  @spec adapter_names() :: [String.t()]
  def adapter_names do
    ["aws_sns", "aws_sqs", "http_webhook", "mllp_forward", "redis_queue", "file", "sink"]
  end

  @doc "Resolve an adapter name string to its implementing module."
  @spec adapter_module(String.t()) :: module() | nil
  def adapter_module(name) do
    %{
      "aws_sns"      => Joy.Destinations.Adapters.AwsSns,
      "aws_sqs"      => Joy.Destinations.Adapters.AwsSqs,
      "http_webhook" => Joy.Destinations.Adapters.HttpWebhook,
      "mllp_forward" => Joy.Destinations.Adapters.MllpForward,
      "redis_queue"  => Joy.Destinations.Adapters.RedisQueue,
      "file"         => Joy.Destinations.Adapters.FileAdapter,
      "sink"         => Joy.Destinations.Adapters.Sink
    }[name]
  end

  @doc "Deliver with retry logic. Uses the destination config's retry settings."
  @spec deliver_with_retry(Joy.HL7.Message.t(), map()) :: :ok | {:error, String.t()}
  def deliver_with_retry(message, dest_config) do
    case adapter_module(dest_config.adapter) do
      nil ->
        {:error, "Unknown adapter: #{dest_config.adapter}"}

      mod ->
        Joy.Destinations.Retry.with_retry(
          fn -> mod.deliver(message, dest_config.config) end,
          dest_config.retry_attempts,
          dest_config.retry_base_ms
        )
    end
  end
end
