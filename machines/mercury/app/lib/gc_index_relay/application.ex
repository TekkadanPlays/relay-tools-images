defmodule GcIndexRelay.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        GcIndexRelayWeb.Telemetry,
        maybe_repo(),
        {Phoenix.PubSub, name: GcIndexRelay.PubSub},
        GcIndexRelay.Graph.SyncWorker,
        # Start a worker by calling: GcIndexRelay.Worker.start_link(arg)
        # {GcIndexRelay.Worker, arg},
        # Start to serve requests, typically the last entry
        GcIndexRelayWeb.Endpoint
      ]
      |> Enum.reject(&is_nil/1)

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: GcIndexRelay.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Returns the Repo if database is available, nil otherwise
  # This allows tests to run without a database connection
  defp maybe_repo do
    if Application.get_env(:gc_index_relay, :start_repo, true) do
      GcIndexRelay.Repo
    else
      nil
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    GcIndexRelayWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
