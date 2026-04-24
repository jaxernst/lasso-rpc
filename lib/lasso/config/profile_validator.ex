defmodule Lasso.Config.ProfileValidator do
  @moduledoc """
  Centralized profile validation with explicit error types.

  This module provides validation for profile identifiers throughout the
  application, ensuring that profiles are valid strings and exist in the
  ConfigStore before being used.

  ## Error Types

  - `:profile_nil` - Profile parameter is nil
  - `:profile_invalid_type` - Profile is not a binary string
  - `:profile_empty` - Profile is an empty string or whitespace-only
  - `:profile_not_found` - Profile doesn't exist in ConfigStore

  ## Usage

  For boundary validation (HTTP, WebSocket, etc.) use explicit validation:

      case ProfileValidator.validate(profile_param) do
        {:ok, validated} -> # proceed with validated profile
        {:error, error_type, message} -> # return error to client
      end

  For internal functions that should never receive invalid profiles, use guards:

      def my_function(profile, chain)
          when is_valid_profile(profile) and is_binary(chain) do
        # implementation
      end

  For legacy compatibility where nil should default to "public", use:

      {:ok, profile} = ProfileValidator.validate_with_default(maybe_nil_profile)
  """

  require Logger
  alias Lasso.Config.ConfigStore

  @default_profile "public"

  @doc """
  Canonical slug for the default/fallback profile.

  Single source of truth — the alias system (`resolve_alias/1`) handles
  legacy-name translation at request boundaries, so this value should only
  change if the canonical slug itself is renamed again.
  """
  @spec default_profile() :: String.t()
  def default_profile, do: @default_profile

  @type validation_error ::
          :profile_nil
          | :profile_invalid_type
          | :profile_empty
          | :profile_not_found

  @type validation_result ::
          {:ok, String.t()}
          | {:error, validation_error(), String.t()}

  @doc """
  Validates a profile parameter and ensures it exists in ConfigStore.

  ## Examples

      iex> ProfileValidator.validate("public")
      {:ok, "public"}

      iex> ProfileValidator.validate(nil)
      {:error, :profile_nil, "Profile parameter is required"}

      iex> ProfileValidator.validate("")
      {:error, :profile_empty, "Profile cannot be empty"}

      iex> ProfileValidator.validate(123)
      {:error, :profile_invalid_type, "Profile must be a string, got: 123"}

      iex> ProfileValidator.validate("nonexistent")
      {:error, :profile_not_found, "Profile 'nonexistent' not found"}
  """
  @spec validate(term()) :: validation_result()
  def validate(nil) do
    {:error, :profile_nil, "Profile parameter is required"}
  end

  def validate(profile) when not is_binary(profile) do
    {:error, :profile_invalid_type, "Profile must be a string, got: #{inspect(profile)}"}
  end

  def validate(profile) when is_binary(profile) do
    trimmed = String.trim(profile)

    if trimmed == "" do
      {:error, :profile_empty, "Profile cannot be empty"}
    else
      canonical = resolve_alias(trimmed)

      case ConfigStore.get_profile(canonical) do
        {:ok, _meta} ->
          {:ok, canonical}

        {:error, :not_found} ->
          {:error, :profile_not_found, "Profile '#{trimmed}' not found"}

        {:error, reason} ->
          Logger.warning("Profile validation failed for '#{canonical}': #{inspect(reason)}")
          {:error, :profile_not_found, "Profile '#{canonical}' not found"}
      end
    end
  end

  @doc """
  Validates a profile with fallback to "public" for nil or empty values.

  This is provided for legacy compatibility where nil or empty string should
  fall back to the "public" profile. New code should prefer explicit profile
  handling using `validate/1`.

  ## Examples

      iex> ProfileValidator.validate_with_default(nil)
      {:ok, "public"}

      iex> ProfileValidator.validate_with_default("")
      {:ok, "public"}

      iex> ProfileValidator.validate_with_default("testnet")
      {:ok, "testnet"}
  """
  @spec validate_with_default(term()) :: validation_result()
  def validate_with_default(nil), do: validate(@default_profile)
  def validate_with_default(""), do: validate(@default_profile)

  def validate_with_default(profile) when is_binary(profile) do
    case String.trim(profile) do
      "" -> validate(@default_profile)
      trimmed -> validate(trimmed)
    end
  end

  def validate_with_default(profile) do
    # Non-string types still get validated normally (will fail)
    validate(profile)
  end

  @doc """
  Validates a profile and raises ArgumentError if invalid.

  Use this for internal functions where invalid profiles indicate a programming
  error rather than user input error.

  ## Examples

      iex> ProfileValidator.validate!("public")
      "public"

      iex> ProfileValidator.validate!(nil)
      ** (ArgumentError) Profile parameter is required

      iex> ProfileValidator.validate!("nonexistent")
      ** (ArgumentError) Profile 'nonexistent' not found
  """
  @spec validate!(term()) :: String.t() | no_return()
  def validate!(profile) do
    case validate(profile) do
      {:ok, validated} ->
        validated

      {:error, _type, message} ->
        raise ArgumentError, message
    end
  end

  @doc """
  Guard for compile-time validation that a value is a non-empty binary.

  Note: This guard only checks that the value is a non-empty string at compile
  time. It does NOT check if the profile exists in ConfigStore (that requires
  runtime validation via `validate/1`).

  Use this guard on public API functions to catch obvious errors early:

      def select_provider(profile, chain, method, opts \\ [])
          when is_valid_profile(profile) and is_binary(chain) do
        # implementation
      end
  """
  defguard is_valid_profile(profile)
           when is_binary(profile) and byte_size(profile) > 0

  @doc """
  Converts validation error types to HTTP status codes.

  Useful for HTTP controllers and plugs that need to return appropriate
  status codes for validation failures.

  ## Examples

      iex> ProfileValidator.error_to_http_status(:profile_nil)
      400

      iex> ProfileValidator.error_to_http_status(:profile_not_found)
      404
  """
  @spec error_to_http_status(validation_error()) :: integer()
  def error_to_http_status(:profile_nil), do: 400
  def error_to_http_status(:profile_invalid_type), do: 400
  def error_to_http_status(:profile_empty), do: 400
  def error_to_http_status(:profile_not_found), do: 404

  @doc """
  Converts validation error types to JSON-RPC error codes.

  Useful for JSON-RPC controllers that need to return appropriate error codes
  for validation failures.

  ## Examples

      iex> ProfileValidator.error_to_jsonrpc_code(:profile_nil)
      -32602

      iex> ProfileValidator.error_to_jsonrpc_code(:profile_not_found)
      -32000
  """
  @spec error_to_jsonrpc_code(validation_error()) :: integer()
  def error_to_jsonrpc_code(:profile_nil), do: -32_602
  def error_to_jsonrpc_code(:profile_invalid_type), do: -32_602
  def error_to_jsonrpc_code(:profile_empty), do: -32_602
  def error_to_jsonrpc_code(:profile_not_found), do: -32_000

  @doc """
  Resolves a profile slug through the configured alias map, returning the
  canonical name.

  The alias map is read from `config :lasso, :profile_aliases` and defaults
  to `%{}`. Lasso Cloud configures this to handle the `default`→`public` and
  `premium`→`managed` rename; OSS deployments are unaffected.
  """
  @spec resolve_alias(String.t()) :: String.t()
  def resolve_alias(slug) when is_binary(slug) do
    aliases = Application.get_env(:lasso, :profile_aliases, %{})
    Map.get(aliases, slug, slug)
  end
end
