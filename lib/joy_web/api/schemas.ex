defmodule JoyWeb.API.Schemas do
  @moduledoc "OpenAPI schemas for Joy API v1 resources."

  alias OpenApiSpex.Schema

  defmodule Channel do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Channel",
      type: :object,
      properties: %{
        id:                    %Schema{type: :integer},
        name:                  %Schema{type: :string},
        description:           %Schema{type: :string, nullable: true},
        mllp_port:             %Schema{type: :integer, minimum: 1024, maximum: 65535},
        started:               %Schema{type: :boolean},
        paused:                %Schema{type: :boolean},
        running:               %Schema{type: :boolean, description: "Live runtime state from ChannelManager"},
        dispatch_concurrency:  %Schema{type: :integer, minimum: 1, maximum: 20},
        pinned_node:           %Schema{type: :string, nullable: true},
        allowed_ips:           %Schema{type: :array, items: %Schema{type: :string}},
        organization_id:       %Schema{type: :integer, nullable: true},
        tls_enabled:           %Schema{type: :boolean},
        tls_verify_peer:       %Schema{type: :boolean},
        tls_cert_expires_at:   %Schema{type: :string, format: "date-time", nullable: true},
        alert_enabled:         %Schema{type: :boolean},
        alert_threshold:       %Schema{type: :integer},
        alert_email:           %Schema{type: :string, format: :email, nullable: true},
        alert_webhook_url:     %Schema{type: :string, nullable: true},
        alert_cooldown_minutes: %Schema{type: :integer},
        ack_code_override:     %Schema{type: :string, enum: ["AA", "AE", "AR"], nullable: true},
        ack_sending_app:       %Schema{type: :string, nullable: true},
        ack_sending_fac:       %Schema{type: :string, nullable: true},
        inserted_at:           %Schema{type: :string, format: "date-time"},
        updated_at:            %Schema{type: :string, format: "date-time"}
      },
      required: [:id, :name, :mllp_port, :started, :paused, :running]
    })
  end

  defmodule ChannelList do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ChannelList",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: Channel}
      },
      required: [:data]
    })
  end

  defmodule ChannelResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ChannelResponse",
      type: :object,
      properties: %{data: Channel},
      required: [:data]
    })
  end

  defmodule ChannelParams do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ChannelParams",
      type: :object,
      properties: %{
        channel: %Schema{
          type: :object,
          properties: %{
            name:                 %Schema{type: :string},
            description:          %Schema{type: :string},
            mllp_port:            %Schema{type: :integer},
            organization_id:      %Schema{type: :integer},
            dispatch_concurrency: %Schema{type: :integer},
            pinned_node:          %Schema{type: :string},
            allowed_ips:          %Schema{type: :array, items: %Schema{type: :string}},
            tls_enabled:          %Schema{type: :boolean},
            alert_enabled:        %Schema{type: :boolean},
            alert_threshold:      %Schema{type: :integer},
            alert_email:          %Schema{type: :string},
            alert_cooldown_minutes: %Schema{type: :integer},
            ack_code_override:    %Schema{type: :string, enum: ["AA", "AE", "AR", ""]},
            ack_sending_app:      %Schema{type: :string},
            ack_sending_fac:      %Schema{type: :string}
          },
          required: [:name, :mllp_port]
        }
      },
      required: [:channel]
    })
  end

  defmodule Organization do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Organization",
      type: :object,
      properties: %{
        id:          %Schema{type: :integer},
        name:        %Schema{type: :string},
        inserted_at: %Schema{type: :string, format: "date-time"},
        updated_at:  %Schema{type: :string, format: "date-time"}
      },
      required: [:id, :name]
    })
  end

  defmodule OrganizationList do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "OrganizationList",
      type: :object,
      properties: %{data: %Schema{type: :array, items: Organization}},
      required: [:data]
    })
  end

  defmodule OrganizationResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "OrganizationResponse",
      type: :object,
      properties: %{data: Organization},
      required: [:data]
    })
  end

  defmodule OrganizationParams do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "OrganizationParams",
      type: :object,
      properties: %{
        organization: %Schema{
          type: :object,
          properties: %{name: %Schema{type: :string}},
          required: [:name]
        }
      },
      required: [:organization]
    })
  end

  defmodule Destination do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Destination",
      description: "Destination config — `config` map excluded (may contain credentials)",
      type: :object,
      properties: %{
        id:              %Schema{type: :integer},
        channel_id:      %Schema{type: :integer},
        name:            %Schema{type: :string},
        adapter:         %Schema{type: :string, enum: ~w[aws_sns aws_sqs http_webhook mllp_forward redis_queue file sink]},
        retry_attempts:  %Schema{type: :integer},
        retry_base_ms:   %Schema{type: :integer},
        enabled:         %Schema{type: :boolean},
        inserted_at:     %Schema{type: :string, format: "date-time"},
        updated_at:      %Schema{type: :string, format: "date-time"}
      },
      required: [:id, :channel_id, :name, :adapter, :enabled]
    })
  end

  defmodule DestinationList do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "DestinationList",
      type: :object,
      properties: %{data: %Schema{type: :array, items: Destination}},
      required: [:data]
    })
  end

  defmodule DestinationResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "DestinationResponse",
      type: :object,
      properties: %{data: Destination},
      required: [:data]
    })
  end

  defmodule DestinationParams do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "DestinationParams",
      type: :object,
      properties: %{
        destination: %Schema{
          type: :object,
          properties: %{
            name:           %Schema{type: :string},
            adapter:        %Schema{type: :string},
            retry_attempts: %Schema{type: :integer},
            retry_base_ms:  %Schema{type: :integer},
            enabled:        %Schema{type: :boolean},
            config:         %Schema{type: :object, description: "Adapter-specific configuration"}
          },
          required: [:name, :adapter]
        }
      },
      required: [:destination]
    })
  end

  defmodule MessageLogEntry do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MessageLogEntry",
      type: :object,
      properties: %{
        id:                 %Schema{type: :integer},
        channel_id:         %Schema{type: :integer},
        message_control_id: %Schema{type: :string, nullable: true},
        status:             %Schema{type: :string, enum: ~w[pending processed failed retried]},
        message_type:       %Schema{type: :string, nullable: true},
        patient_id:         %Schema{type: :string, nullable: true},
        error:              %Schema{type: :string, nullable: true},
        inserted_at:        %Schema{type: :string, format: "date-time"}
      },
      required: [:id, :channel_id, :status]
    })
  end

  defmodule MessageLogList do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MessageLogList",
      type: :object,
      properties: %{data: %Schema{type: :array, items: MessageLogEntry}},
      required: [:data]
    })
  end

  defmodule MessageLogEntryResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MessageLogEntryResponse",
      type: :object,
      properties: %{data: MessageLogEntry},
      required: [:data]
    })
  end

  defmodule PurgeResult do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PurgeResult",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            deleted:  %Schema{type: :integer},
            archived: %Schema{type: :integer}
          },
          required: [:deleted, :archived]
        }
      },
      required: [:data]
    })
  end

  defmodule StatusResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "StatusResponse",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{status: %Schema{type: :string}},
          required: [:status]
        }
      },
      required: [:data]
    })
  end

  defmodule TokenParams do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TokenParams",
      type: :object,
      properties: %{
        email:    %Schema{type: :string, format: :email},
        password: %Schema{type: :string, format: :password},
        name:     %Schema{type: :string, description: "Human-readable label for the token"},
        ttl_days: %Schema{type: :integer, minimum: 1, maximum: 90,
                          description: "Token lifetime in days (default 90, max 90)"}
      },
      required: [:email, :password, :name]
    })
  end

  defmodule TokenCreatedResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TokenCreatedResponse",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            id:         %Schema{type: :integer},
            name:       %Schema{type: :string},
            token:      %Schema{type: :string, description: "Plain token — shown once, store it now"},
            expires_at: %Schema{type: :string, format: "date-time"}
          },
          required: [:id, :name, :token, :expires_at]
        }
      },
      required: [:data]
    })
  end

  defmodule ErrorResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ErrorResponse",
      type: :object,
      properties: %{errors: %Schema{type: :object}},
      required: [:errors]
    })
  end
end
