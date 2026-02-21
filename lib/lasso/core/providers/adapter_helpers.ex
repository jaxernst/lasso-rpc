defmodule Lasso.RPC.Providers.AdapterHelpers do
  @moduledoc """
  Shared utilities for provider adapters.

  This module provides common functionality used across multiple adapter implementations,
  reducing code duplication and ensuring consistent behavior.
  """

  alias Lasso.RPC.ChainState

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

  @spec validate_block_range(list(), map(), pos_integer()) :: :ok | {:error, term()}
  def validate_block_range([%{"fromBlock" => from, "toBlock" => to}], ctx, limit) do
    with {:ok, range} <- compute_block_range(from, to, ctx),
         true <- range > limit do
      {:error, {:param_limit, "max #{limit} block range (got #{range})"}}
    else
      _ -> :ok
    end
  end

  def validate_block_range(_params, _ctx, _limit), do: :ok

  @spec compute_block_range(term(), term(), map()) :: {:ok, non_neg_integer()} | :error
  def compute_block_range(from_block, to_block, ctx) do
    with {:ok, from_num} <- parse_block_number(from_block, ctx),
         {:ok, to_num} <- parse_block_number(to_block, ctx) do
      {:ok, abs(to_num - from_num)}
    else
      _ -> :error
    end
  end

  @spec parse_block_number(term(), map()) :: {:ok, non_neg_integer()} | :error
  def parse_block_number("latest", ctx), do: {:ok, estimate_current_block(ctx)}
  def parse_block_number("earliest", _ctx), do: {:ok, 0}
  def parse_block_number("pending", ctx), do: {:ok, estimate_current_block(ctx)}

  def parse_block_number("0x" <> hex, _ctx) do
    case Integer.parse(hex, 16) do
      {num, ""} -> {:ok, num}
      _ -> :error
    end
  end

  def parse_block_number(num, _ctx) when is_integer(num), do: {:ok, num}
  def parse_block_number(_value, _ctx), do: :error

  @spec estimate_current_block(map()) :: non_neg_integer()
  def estimate_current_block(ctx) do
    chain = Map.get(ctx, :chain, "ethereum")

    case ChainState.consensus_height(chain) do
      {:ok, height} -> height
      {:error, _} -> 0
    end
  end
end
