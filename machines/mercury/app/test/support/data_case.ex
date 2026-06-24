defmodule GcIndexRelay.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use GcIndexRelay.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias GcIndexRelay.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import GcIndexRelay.DataCase
    end
  end

  setup tags do
    _ = GcIndexRelay.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Starts a sandbox owner for the Repo when it is started in this environment.

  Returns the sandbox owner pid when the Repo is started, otherwise `nil`.
  """
  @spec setup_sandbox(map()) :: pid() | nil
  def setup_sandbox(_tags) do
    if Application.get_env(:gc_index_relay, :start_repo, true) do
      # Always use shared: false so concurrent test *modules* (ExUnit default) do not
      # clobber each other via `mode(repo, {:shared, _})`. The test process is allowed on
      # the owner checkout; HTTP tests rely on `Phoenix.Ecto.SQL.Sandbox` + metadata header.
      pid = Ecto.Adapters.SQL.Sandbox.start_owner!(GcIndexRelay.Repo, shared: false)
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
      empty_nostr_event_tables!(GcIndexRelay.Repo)
      pid
    end
  end

  defp empty_nostr_event_tables!(repo) do
    alias GcIndexRelay.Nostr.{Event, Tag}

    _ = repo.delete_all(Tag)
    _ = repo.delete_all(Event)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
