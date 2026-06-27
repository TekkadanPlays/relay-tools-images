defmodule GcIndexRelayWeb.Router do
  use GcIndexRelayWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {GcIndexRelayWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", GcIndexRelayWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  get "/health", GcIndexRelayWeb.HealthController, :check

  scope "/api", GcIndexRelayWeb do
    pipe_through :api

    get "/", ApiController, :index
    get "/events", FilterController, :index
    post "/events/filter", FilterController, :query
    post "/publications/search", PublicationSearchController, :search
    post "/publications/content/search", PublicationContentSearchController, :search
    resources "/events", EventController, only: [:show, :create, :delete]
  end

  # ── Auth endpoints (public, no token required) ──
  scope "/api/auth", GcIndexRelayWeb do
    pipe_through :api

    post "/claim-admin", AuthController, :claim_admin
    post "/token", AuthController, :create_token
  end

  # ── Admin-only pipeline ──
  pipeline :admin_api do
    plug :accepts, ["json"]
    plug GcIndexRelayWeb.Plugs.RequireRole, :admin
  end

  # ── Admin endpoints (require admin role) ──
  scope "/api/admin", GcIndexRelayWeb do
    pipe_through :admin_api

    get "/stats", AdminController, :stats
    delete "/events/purge", AdminController, :purge_events
    post "/ban", AdminController, :ban
    delete "/ban/:pubkey", AdminController, :unban
    get "/bans", AdminController, :list_bans
    get "/admins", AdminController, :list_admins

    # Moderator management (admin-only)
    post "/moderators", AdminController, :appoint_mod
    delete "/moderators/:pubkey/:community_atag", AdminController, :remove_mod
    get "/moderators", AdminController, :list_mods
  end

  # ── Authenticated pipeline (any valid token, mod or admin) ──
  pipeline :authenticated_api do
    plug :accepts, ["json"]
    plug GcIndexRelayWeb.Plugs.RequireRole, :authenticated
  end

  # ── Moderation endpoints (require mod or admin role, checked per-action) ──
  scope "/api/mod", GcIndexRelayWeb do
    pipe_through :authenticated_api

    post "/hide/:event_id", ModerationController, :hide_event
    post "/unhide/:event_id", ModerationController, :unhide_event
    post "/ban", ModerationController, :ban
    delete "/ban/:pubkey", ModerationController, :unban
    post "/report", ModerationController, :create_report
    get "/reports", ModerationController, :list_reports
    post "/reports/:id/resolve", ModerationController, :resolve_report
    get "/hidden", ModerationController, :list_hidden
  end

  def swagger_info do
    relay_info = Application.fetch_env!(:gc_index_relay, :relay_info)

    title = Keyword.fetch!(relay_info, :name)
    version = Keyword.fetch!(relay_info, :version) |> to_string()
    base_desc = Keyword.fetch!(relay_info, :description)

    description =
      base_desc <>
        supported_nips_swagger_suffix(Keyword.get(relay_info, :supported_nips, [])) <>
        "\n\nRelay information document available at `GET /` with `Accept: application/nostr+json`."

    %{
      # `wss` reserved for a future NIP-01 WebSocket endpoint; REST-only for now.
      schemes: ["https", "wss"],
      info: %{
        version: version,
        title: title,
        description: description
      },
      consumes: ["application/json"],
      produces: ["application/json"]
    }
  end

  defp supported_nips_swagger_suffix([]), do: ""

  defp supported_nips_swagger_suffix(nips) do
    "\n\n**Supported NIPs:** " <> Enum.map_join(nips, ", ", &"NIP-#{&1}")
  end

  scope "/api/swagger" do
    forward "/", PhoenixSwagger.Plug.SwaggerUI,
      otp_app: :gc_index_relay,
      swagger_file: "swagger.json"
  end

  # Other scopes may use custom stacks.
  # scope "/api", GcIndexRelayWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:gc_index_relay, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: GcIndexRelayWeb.Telemetry
    end
  end
end
