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
  def parse_block_number("latest", ctx), do: resolve_current_block(ctx)
  def parse_block_number("earliest", _ctx), do: {:ok, 0}
  def parse_block_number("pending", ctx), do: resolve_current_block(ctx)

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

  defp resolve_current_block(ctx) do
    case estimate_current_block(ctx) do
      0 -> :error
      height -> {:ok, height}
    end
  end

  @doc """
  Validates that a state method's block parameter is within the provider's archive depth.

  Extracts the last element of the params list (the block tag), parses it,
  and compares `current_block - target_block` against `max_age`.
  Fail-open: if current_block is unknown or block tag is unparseable, allows the request.
  """
  @spec validate_block_age(list(), map(), pos_integer()) :: :ok | {:error, term()}
  def validate_block_age(params, ctx, max_age) when is_list(params) and is_integer(max_age) do
    block_param = List.last(params)

    case parse_block_tag(block_param) do
      {:ok, :latest} ->
        :ok

      {:ok, block_num} when is_integer(block_num) ->
        current_block = estimate_current_block(ctx)

        if current_block == 0 do
          :ok
        else
          age = current_block - block_num

          if age <= max_age do
            :ok
          else
            {:error,
             {:requires_archival, "Block is #{age} blocks old, max archive depth: #{max_age}"}}
          end
        end

      _ ->
        :ok
    end
  end

  def validate_block_age(_params, _ctx, _max_age), do: :ok

  defp parse_block_tag("latest"), do: {:ok, :latest}
  defp parse_block_tag("pending"), do: {:ok, :latest}
  defp parse_block_tag("earliest"), do: {:ok, 0}

  defp parse_block_tag("0x" <> hex) do
    case Integer.parse(hex, 16) do
      {num, ""} -> {:ok, num}
      _ -> :error
    end
  end

  defp parse_block_tag(_), do: :error
end
