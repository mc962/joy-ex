defmodule JoyWeb.API.V1.MetricsController do
  use JoyWeb, :controller

  alias Joy.{Channels, ChannelManager, ChannelStats}

  def index(conn, _params) do
    lines =
      Channels.list_channels()
      |> Enum.flat_map(fn ch ->
        stats   = ChannelStats.get_today(ch.id)
        running = if ChannelManager.channel_running?(ch.id), do: 1, else: 0
        label   = ~s(channel="#{ch.name}")

        [
          "joy_channel_messages_received_today{#{label}} #{stats.received}",
          "joy_channel_messages_processed_today{#{label}} #{stats.processed}",
          "joy_channel_messages_failed_today{#{label}} #{stats.failed}",
          "joy_channel_running{#{label}} #{running}"
        ]
      end)

    conn
    |> put_resp_content_type("text/plain; version=0.0.4")
    |> send_resp(200, Enum.join(lines, "\n") <> "\n")
  end
end
