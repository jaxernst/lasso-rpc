defmodule Lasso.Config.Backend do
  @moduledoc """
  Behaviour for configuration backends that load and store profile configurations.

  Profiles are the top-level isolation boundary in Lasso. Each profile contains
  its own set of chains and providers with independent configuration.

  ## Implementations

  - `Lasso.Config.Backend.File` - File-based YAML profiles (OSS default)
  - Future: `LassoCloud.Config.Backend.Database` - PostgreSQL-backed profiles (SaaS)

  ## Profile Specification

  A profile_spec is a map containing:
  - `:slug` - Unique identifier (used in URLs)
  - `:name` - Human-readable display name
  - `:type` - Profile type (:free | :standard | :premium | :byok)
  - `:default_rps_limit` - Default requests per second limit
  - `:default_burst_limit` - Default burst limit
  - `:chains` - Map of chain_name => chain configuration
  """

  @type profile_spec :: %{
          slug: String.t(),
          name: String.t(),
          type: :free | :standard | :premium | :byok,
          default_rps_limit: pos_integer(),
          default_burst_limit: pos_integer(),
          chains: %{String.t() => map()}
        }

  @type state :: term()

  @doc """
  Initialize the backend with configuration options.

  Called once at application startup. Returns backend state that will be
  passed to subsequent callbacks.
  """
  @callback init(config :: keyword()) :: {:ok, state()} | {:error, term()}

  @doc """
  Load all profiles from the backend.

  Returns a list of all profile specifications. This is called at startup
  and during reload operations.

  Implementations should fail-fast on the first invalid profile to ensure
  configuration errors are caught at deploy time.
  """
  @callback load_all(state()) :: {:ok, [profile_spec()]} | {:error, term()}

  @doc """
  Load a single profile by slug.

  Returns the profile specification or an error if not found.
  """
  @callback load(state(), slug :: String.t()) ::
              {:ok, profile_spec()} | {:error, :not_found | term()}

  @doc """
  Save a profile configuration.

  Optional callback for backends that support writes (e.g., database backend).
  File backend may implement this for hot reload support.
  """
  @callback save(state(), slug :: String.t(), yaml :: String.t()) :: :ok | {:error, term()}

  @doc """
  Delete a profile.

  Optional callback for backends that support deletion.
  """
  @callback delete(state(), slug :: String.t()) :: :ok | {:error, term()}

  @optional_callbacks [save: 3, delete: 2]

  @doc """
  Get the configured backend module.
  """
  def backend_module do
    Application.get_env(:lasso, :config_backend, Lasso.Config.Backend.File)
  end

  @doc """
  Get the backend configuration options.
  """
  def backend_config do
    Application.get_env(:lasso, :config_backend_config, profiles_dir: "config/profiles")
  end
end
