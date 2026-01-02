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

  ## Default Profile
  Routes without a profile slug in the URL use the "default" profile.
  Ensure `config/profiles/default.yml` exists at startup.
  """

  import Plug.Conn

  alias Lasso.Config.{ConfigStore, ProfileValidator}

  @default_profile "default"

  def init(opts), do: opts

  def call(conn, _opts) do
    profile_slug = Map.get(conn.path_params, "profile", @default_profile)

    case ProfileValidator.validate(profile_slug) do
      {:ok, validated_slug} ->
        # Profile validated, now fetch metadata
        case ConfigStore.get_profile(validated_slug) do
          {:ok, profile_meta} ->
            conn
            |> assign(:profile_slug, validated_slug)
            |> assign(:profile, profile_meta)

          {:error, :not_found} ->
            # This should not happen if validator passed, but handle defensively
            return_error(conn, :profile_not_found, "Profile '#{validated_slug}' not found")
        end

      {:error, error_type, message} ->
        return_error(conn, error_type, message)
    end
  end

  # Private helper to return error responses
  defp return_error(conn, error_type, message) do
    http_status = ProfileValidator.error_to_http_status(error_type)
    jsonrpc_code = ProfileValidator.error_to_jsonrpc_code(error_type)

    conn
    |> put_status(http_status)
    |> Phoenix.Controller.json(%{
      jsonrpc: "2.0",
      error: %{
        code: jsonrpc_code,
        message: message,
        data: %{error_type: error_type}
      },
      id: nil
    })
    |> halt()
  end
end
