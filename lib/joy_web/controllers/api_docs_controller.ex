defmodule JoyWeb.ApiDocsController do
  use JoyWeb, :controller

  def index(conn, _params) do
    render(conn, :index)
  end
end
