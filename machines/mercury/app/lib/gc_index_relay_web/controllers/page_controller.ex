defmodule GcIndexRelayWeb.PageController do
  use GcIndexRelayWeb, :controller

  def home(conn, _params) do
    render(conn, :home, page_title: "Home")
  end
end
