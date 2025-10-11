defmodule Lasso.RPC.Providers.AdapterHelpers do
  @moduledoc """
  Shared utilities for provider adapters.

  This module provides common functionality used across multiple adapter implementations,
  reducing code duplication and ensuring consistent behavior.
  """

  @doc """
  Reads adapter config value from context with fallback to default.

  Adapters use this helper to read per-provider configuration overrides
  from the `adapter_config` field in provider configuration. If no override
  is present, the default value is returned.

  ## Parameters

    * `ctx` - Request context containing provider_config
    * `key` - Atom key for the config value (e.g., :eth_get_logs_block_range)
    * `default` - Default value to use if key is not found in adapter_config

  ## Examples

      iex> ctx = %{
      ...>   provider_config: %{
      ...>     adapter_config: %{max_block_range: 100}
      ...>   }
      ...> }
      iex> AdapterHelpers.get_adapter_config(ctx, :max_block_range, 50)
      100

      iex> ctx = %{}
      iex> AdapterHelpers.get_adapter_config(ctx, :max_block_range, 50)
      50

      iex> ctx = %{provider_config: %{adapter_config: %{}}}
      iex> AdapterHelpers.get_adapter_config(ctx, :unknown_key, 42)
      42
  """
  @spec get_adapter_config(map(), atom(), any()) :: any()
  def get_adapter_config(ctx, key, default) when is_map(ctx) and is_atom(key) do
    adapter_config =
      ctx
      |> Map.get(:provider_config, %{})
      |> Map.get(:adapter_config)

    case adapter_config do
      nil -> default
      %{} = config -> Map.get(config, key, default)
      _ -> default
    end
  end
end
