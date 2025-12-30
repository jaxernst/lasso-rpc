defmodule LassoWeb.Plugs.ProfileResolverPlug do
  @moduledoc """
  Resolves and validates the profile from the request path.

  Extracts the profile slug from `conn.path_params["profile"]`, validates it exists
  in ConfigStore, and assigns profile metadata to the connection.

  ## Assigns
  - `:profile_slug` - The profile slug from the URL (e.g., "default", "premium")
  - `:profile` - Full profile metadata from ConfigStore

  ## Fallback
  If no profile is specified in the path, defaults to "default" profile.
  """

  import Plug.Conn
  require Logger

  alias Lasso.Config.ConfigStore

  def init(opts), do: opts

  def call(conn, _opts) do
    profile_slug = get_profile_slug(conn)

    case ConfigStore.get_profile(profile_slug) do
      {:ok, profile_meta} ->
        conn
        |> assign(:profile_slug, profile_slug)
        |> assign(:profile, profile_meta)

      {:error, :not_found} ->
        Logger.warning("Profile not found: #{profile_slug}, falling back to default")

        # Fallback to default profile
        case ConfigStore.get_profile("default") do
          {:ok, default_profile} ->
            conn
            |> assign(:profile_slug, "default")
            |> assign(:profile, default_profile)

          {:error, :not_found} ->
            # No default profile - this is a critical error
            conn
            |> put_status(503)
            |> Phoenix.Controller.json(%{
              jsonrpc: "2.0",
              error: %{
                code: -32000,
                message: "Service unavailable: no profiles configured"
              },
              id: nil
            })
            |> halt()
        end
    end
  end

  # Extract profile slug from path params, or default to "default"
  defp get_profile_slug(conn) do
    Map.get(conn.path_params, "profile", "default")
  end
end
