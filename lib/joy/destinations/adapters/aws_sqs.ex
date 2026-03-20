defmodule Joy.Destinations.Adapters.AwsSqs do
  @moduledoc """
  Destination adapter: AWS SQS. Enqueues HL7 as a JSON message.

  Config: "queue_url" (required), "aws_region" (required),
  "aws_access_key_id" / "aws_secret_access_key" (optional, prefer IAM roles).

  Message body: JSON with keys hl7, message_type, sending_facility, timestamp.

  # GO-TRANSLATION: aws-sdk-go-v2 sqs.Client.SendMessage(); same semantics.
  """

  @behaviour Joy.Destinations.Destination

  @impl true
  def adapter_name, do: "aws_sqs"

  @impl true
  def deliver(msg, config) do
    aws_config = build_aws_config(config)

    body = Jason.encode!(%{
      hl7: Joy.HL7.to_string(msg),
      message_type: Joy.HL7.get(msg, "MSH.9"),
      sending_facility: Joy.HL7.get(msg, "MSH.4"),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })

    config["queue_url"]
    |> ExAws.SQS.send_message(body)
    |> ExAws.request(aws_config)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, "SQS send failed: #{inspect(reason)}"}
    end
  end

  @impl true
  def validate_config(config) do
    required = ["queue_url", "aws_region"]
    missing = Enum.filter(required, &(is_nil(config[&1]) or config[&1] == ""))
    if missing == [], do: :ok, else: {:error, "Missing: #{Enum.join(missing, ", ")}"}
  end

  defp build_aws_config(config) do
    base = [region: config["aws_region"]]
    if config["aws_access_key_id"] && config["aws_access_key_id"] != "" do
      base ++ [access_key_id: config["aws_access_key_id"],
               secret_access_key: config["aws_secret_access_key"]]
    else
      base
    end
  end
end
