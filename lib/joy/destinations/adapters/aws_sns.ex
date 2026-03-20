defmodule Joy.Destinations.Adapters.AwsSns do
  @moduledoc """
  Destination adapter: AWS SNS. Publishes the HL7 message as an SNS notification.

  Config keys: "topic_arn" (required), "aws_region" (required),
  "aws_access_key_id" / "aws_secret_access_key" (optional — prefer IAM roles
  when deployed on EC2/ECS as no credentials need to be stored at all).

  Message body = raw HL7 string. Message attributes carry metadata for filtering.

  # GO-TRANSLATION:
  # aws-sdk-go-v2: sns.Client.Publish(ctx, &sns.PublishInput{...})
  # Config maps directly to ExAws config options.
  """

  # Dialyzer false positive: ExAws PLT lacks complete return-type specs for
  # ExAws.SNS.publish/2 + ExAws.request/2, causing it to infer :none.
  @dialyzer {:nowarn_function, deliver: 2}

  @behaviour Joy.Destinations.Destination

  @impl true
  def adapter_name, do: "aws_sns"

  @impl true
  def deliver(msg, config) do
    aws_config = build_aws_config(config)
    raw = Joy.HL7.to_string(msg)
    msg_type = Joy.HL7.get(msg, "MSH.9") || ""
    facility = Joy.HL7.get(msg, "MSH.4") || ""

    attrs = %{
      "message_type" => %{data_type: "String", string_value: msg_type},
      "sending_facility" => %{data_type: "String", string_value: facility}
    }

    ExAws.SNS.publish(raw, topic_arn: config["topic_arn"], message_attributes: attrs)
    |> ExAws.request(aws_config)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, "SNS publish failed: #{inspect(reason)}"}
    end
  end

  @impl true
  def validate_config(config) do
    required = ["topic_arn", "aws_region"]
    missing = Enum.filter(required, &(is_nil(config[&1]) or config[&1] == ""))
    if missing == [], do: :ok, else: {:error, "Missing required fields: #{Enum.join(missing, ", ")}"}
  end

  defp build_aws_config(config) do
    base = [region: config["aws_region"]]
    if config["aws_access_key_id"] && config["aws_access_key_id"] != "" do
      base ++
        [access_key_id: config["aws_access_key_id"],
         secret_access_key: config["aws_secret_access_key"]]
    else
      base
    end
  end
end
