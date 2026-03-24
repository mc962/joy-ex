defmodule JoyWeb.API.ApiSpec do
  @moduledoc "Root OpenAPI 3.0 specification for Joy API v1."
  @behaviour OpenApiSpex.OpenApi

  alias OpenApiSpex.{Components, Info, OpenApi, Paths, SecurityScheme, Server}
  alias JoyWeb.Router

  @impl OpenApiSpex.OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title:       "Joy HL7 API",
        description: "REST API for managing Joy channels, organizations, destinations, and message log entries.",
        version:     "1.0"
      },
      servers: [%Server{url: "/"}],
      paths: Router |> Paths.from_router() |> Map.filter(fn {path, _} -> String.starts_with?(path, "/api/v1") end),
      components: %Components{
        schemas: %{
          "Channel"                => JoyWeb.API.Schemas.Channel.schema(),
          "ChannelList"            => JoyWeb.API.Schemas.ChannelList.schema(),
          "ChannelResponse"        => JoyWeb.API.Schemas.ChannelResponse.schema(),
          "ChannelParams"          => JoyWeb.API.Schemas.ChannelParams.schema(),
          "Organization"           => JoyWeb.API.Schemas.Organization.schema(),
          "OrganizationList"       => JoyWeb.API.Schemas.OrganizationList.schema(),
          "OrganizationResponse"   => JoyWeb.API.Schemas.OrganizationResponse.schema(),
          "OrganizationParams"     => JoyWeb.API.Schemas.OrganizationParams.schema(),
          "Destination"            => JoyWeb.API.Schemas.Destination.schema(),
          "DestinationList"        => JoyWeb.API.Schemas.DestinationList.schema(),
          "DestinationResponse"    => JoyWeb.API.Schemas.DestinationResponse.schema(),
          "DestinationParams"      => JoyWeb.API.Schemas.DestinationParams.schema(),
          "MessageLogEntry"        => JoyWeb.API.Schemas.MessageLogEntry.schema(),
          "MessageLogList"         => JoyWeb.API.Schemas.MessageLogList.schema(),
          "MessageLogEntryResponse" => JoyWeb.API.Schemas.MessageLogEntryResponse.schema(),
          "PurgeResult"            => JoyWeb.API.Schemas.PurgeResult.schema(),
          "StatusResponse"         => JoyWeb.API.Schemas.StatusResponse.schema(),
          "ErrorResponse"          => JoyWeb.API.Schemas.ErrorResponse.schema(),
          "TokenParams"            => JoyWeb.API.Schemas.TokenParams.schema(),
          "TokenCreatedResponse"   => JoyWeb.API.Schemas.TokenCreatedResponse.schema()
        },
        securitySchemes: %{
          "BearerAuth" => %SecurityScheme{type: "http", scheme: "bearer",
            description: "API token from /users/settings. Prefix: joy_"}
        }
      }
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
