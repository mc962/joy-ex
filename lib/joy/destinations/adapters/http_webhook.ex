defmodule Joy.Destinations.Adapters.HttpWebhook do
  @moduledoc """
  Destination adapter: HTTP Webhook. POSTs HL7 as JSON to a configured URL.

  Config: "url" (required), "headers" (map, optional), "timeout_ms" (default 10000).

  # GO-TRANSLATION: net/http.Client + http.NewRequest("POST", ...).
  # Req's API is similar to Go's http.Client but with a builder pattern.
  """

  @behaviour Joy.Destinations.Destination

  @impl true
  def adapter_name, do: "http_webhook"

  @impl true
  def deliver(msg, config) do
    body = %{
      hl7: Joy.HL7.to_string(msg),
      message_type: Joy.HL7.get(msg, "MSH.9"),
      sending_facility: Joy.HL7.get(msg, "MSH.4"),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    extra_headers = config |> Map.get("headers", %{}) |> Map.to_list()
    timeout = Map.get(config, "timeout_ms", 10_000)

    try do
      response = Req.post!(config["url"],
        json: body,
        headers: extra_headers,
        receive_timeout: timeout
      )
      if response.status in 200..299, do: :ok, else: {:error, "HTTP #{response.status}"}
    rescue
      e -> {:error, "Webhook error: #{Exception.message(e)}"}
    end
  end

  @impl true
  def validate_config(config) do
    if config["url"] && config["url"] != "",
      do: :ok,
      else: {:error, "url is required"}
  end
end
