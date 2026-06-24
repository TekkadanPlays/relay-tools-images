defmodule Mix.Tasks.Test.Integration do
  use Mix.Task

  @shortdoc "Runs integration tests with REQUIRE_DB=true (requires PostgreSQL)"

  @moduledoc """
  Creates the test database if needed, runs migrations, then runs tests tagged `:integration`.

  Spawns a subprocess with `REQUIRE_DB=true` so the application starts `GcIndexRelay.Repo`
  under `MIX_ENV=test`. Extra args are forwarded to `mix test` (e.g. `--failed`, `--trace` for line-by-line output).
  """

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("loadconfig")

    argv =
      [
        "REQUIRE_DB=true",
        "MIX_ENV=test",
        "mix",
        "do",
        "ecto.create",
        "--quiet",
        "+",
        "ecto.migrate",
        "--quiet",
        "+",
        "test",
        "--only",
        "integration"
      ] ++ args

    {_output, exit_code} =
      System.cmd("env", argv, into: IO.stream(:stdio, :line), cd: File.cwd!())

    System.halt(exit_code)
  end
end
