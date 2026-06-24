defmodule GcIndexRelayWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use GcIndexRelayWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint GcIndexRelayWeb.Endpoint

      use GcIndexRelayWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import GcIndexRelayWeb.ConnCase
    end
  end

  setup tags do
    sandbox_owner = GcIndexRelay.DataCase.setup_sandbox(tags)

    conn =
      Phoenix.ConnTest.build_conn()
      |> maybe_put_sql_sandbox_user_agent(sandbox_owner)

    {:ok, conn: conn}
  end

  defp maybe_put_sql_sandbox_user_agent(conn, nil), do: conn

  defp maybe_put_sql_sandbox_user_agent(conn, owner) when is_pid(owner) do
    if Application.get_env(:gc_index_relay, :sql_sandbox, false) do
      metadata = Phoenix.Ecto.SQL.Sandbox.metadata_for(GcIndexRelay.Repo, owner)

      Plug.Conn.put_req_header(
        conn,
        "user-agent",
        Phoenix.Ecto.SQL.Sandbox.encode_metadata(metadata)
      )
    else
      conn
    end
  end
end
