defmodule JoyWeb.HealthController do
  use JoyWeb, :controller

  def check(conn, _params) do
    send_resp(conn, 200, "ok")
  end
end
