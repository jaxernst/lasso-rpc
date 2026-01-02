defmodule LassoWeb.Plugs.ProfileResolverPlug do
  @moduledoc """
  Resolves and validates the profile from the request path.

  Extracts the profile slug from `conn.path_params["profile"]`, validates it exists
  in ConfigStore, and assigns profile metadata to the connection.

  ## Assigns
  - `:profile_slug` - The profile slug from the URL (e.g., "default", "premium")
  - `:profile` - Full profile metadata from ConfigStore

  ## Default Profile
  Routes without a profile slug in the URL use the "default" profile.
  Ensure `config/profiles/default.yml` exists.
  """

  import Plug.Conn

  alias Lasso.Config.ConfigStore

  @default_profile "default"

  def init(opts), do: opts

  def call(conn, _opts) do
    profile_slug = Map.get(conn.path_params, "profile", @default_profile)

    case ConfigStore.get_profile(profile_slug) do
      {:ok, profile_meta} ->
        conn
        |> assign(:profile_slug, profile_slug)
        |> assign(:profile, profile_meta)

      {:error, :not_found} ->
        conn
        |> put_status(503)
        |> Phoenix.Controller.json(%{
          jsonrpc: "2.0",
          error: %{
            code: -32000,
            message: "Profile not found: #{profile_slug}"
          },
          id: nil
        })
        |> halt()
    end
  end
end
