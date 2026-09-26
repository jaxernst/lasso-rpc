defmodule Lasso.Operator.Commands do
  @moduledoc "Release commands for validating and applying file profiles."

  alias Lasso.Config.Backend.File, as: FileBackend
  alias Lasso.Config.ConfigStore

  @doc "Read and validate file profiles without changing disk or the active configuration."
  @spec check_config(String.t() | nil) :: {:ok, non_neg_integer()} | {:error, term()}
  def check_config(profiles_dir \\ nil) do
    with {:ok, dir} <- resolve_profiles_dir(profiles_dir),
         {:ok, specs} <- FileBackend.validate_all(dir),
         :ok <- ConfigStore.validate_profile_specs(specs) do
      {:ok, length(specs)}
    end
  end

  @doc "Validate files, then ask the running ConfigStore to apply them atomically."
  @spec reload() :: :ok | {:error, term()}
  def reload do
    case check_config() do
      {:ok, _count} -> ConfigStore.reload()
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec check_config!() :: :ok
  def check_config! do
    case check_config() do
      {:ok, count} ->
        IO.puts("Configuration valid: #{count} profiles")
        :ok

      {:error, reason} ->
        raise "Configuration invalid: #{inspect(reason)}"
    end
  end

  @doc false
  @spec reload!() :: :ok
  def reload! do
    case reload() do
      :ok ->
        IO.puts("Configuration reloaded")
        :ok

      {:error, reason} ->
        raise "Configuration reload rejected: #{inspect(reason)}"
    end
  end

  defp resolve_profiles_dir(dir) when is_binary(dir), do: {:ok, dir}

  defp resolve_profiles_dir(nil) do
    case Application.get_env(:lasso, :backend_config, []) do
      opts when is_list(opts) ->
        case Keyword.get(opts, :backend, FileBackend) do
          FileBackend ->
            case Keyword.get(opts, :config, []) do
              config when is_list(config) ->
                {:ok, Keyword.get(config, :profiles_dir, "config/profiles")}

              _ ->
                {:error, :invalid_backend_configuration}
            end

          backend ->
            {:error, {:unsupported_backend, backend}}
        end

      _ ->
        {:error, :invalid_backend_configuration}
    end
  end
end
