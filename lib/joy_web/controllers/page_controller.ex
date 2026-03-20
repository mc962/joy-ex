defmodule JoyWeb.PageController do
  use JoyWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
