defmodule LassoWeb.Plugs.ProfileResolverPlug do
  @moduledoc """
  Resolves and validates the profile from the request path.

  Extracts the profile slug from `conn.path_params["profile"]`, validates it exists
  in ConfigStore using ProfileValidator, and assigns profile metadata to the connection.

  ## Validation

  Profiles are validated through ProfileValidator which checks:
  - Profile parameter is present and valid type
  - Profile is not empty or whitespace-only
  - Profile exists in ConfigStore

  Invalid profiles result in appropriate HTTP error responses with JSON-RPC error codes.

  ## Assigns
  - `:profile_slug` - The validated profile slug from the URL (e.g., "default", "testnet")
  - `:profile` - Full profile metadata from ConfigStore

  ## Default Profile Fallback

  Routes without an explicit profile slug in the URL (legacy routes) automatically
  use the "default" profile. This provides backward compatibility for:

  - `POST /rpc/:chain_id` → Uses "default" profile
  - `POST /rpc/fastest/:chain_id` → Uses "default" profile
  - `POST /rpc/provider/:provider_id/:chain_id` → Uses "default" profile

  Profile-aware routes explicitly include the profile:

  - `POST /rpc/profile/:profile/:chain_id` → Uses specified profile
  - `POST /rpc/profile/:profile/fastest/:chain_id` → Uses specified profile

  **Important**: Ensure `config/profiles/default.yml` exists at startup, or default profile
  routes will fail with 404 errors.
  """

  import Plug.Conn

  alias Lasso.Config.{ConfigStore, ProfileValidator}

  @default_profile "default"

  def init(opts), do: opts

  def call(conn, _opts) do
    profile_slug = Map.get(conn.path_params, "profile", @default_profile)

    case ProfileValidator.validate(profile_slug) do
      {:ok, validated_slug} ->
        case ConfigStore.get_profile(validated_slug) do
          {:ok, profile_meta} ->
            conn
            |> assign(:profile_slug, validated_slug)
            |> assign(:profile, profile_meta)

          {:error, :not_found} ->
            return_error(conn, :profile_not_found, "Profile '#{validated_slug}' not found")
        end

      {:error, error_type, message} ->
        return_error(conn, error_type, message)
    end
  end

  defp return_error(conn, error_type, message) do
    {http_status, jsonrpc_code} = error_codes(error_type)

    conn
    |> put_status(http_status)
    |> put_resp_content_type("application/json")
    |> Phoenix.Controller.json(%{
      jsonrpc: "2.0",
      error: %{code: jsonrpc_code, message: message, data: %{error_type: error_type}},
      id: nil
    })
    |> halt()
  end

  defp error_codes(error_type) do
    {ProfileValidator.error_to_http_status(error_type), ProfileValidator.error_to_jsonrpc_code(error_type)}
  end
end
