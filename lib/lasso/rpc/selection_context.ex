defmodule Lasso.RPC.SelectionContext do
  @moduledoc """
  Context object for provider selection containing all necessary parameters
  and dependencies for making routing decisions.

  This eliminates parameter passing complexity and provides a clean
  interface for selection strategies.
  """

  @enforce_keys [:chain, :method]
  defstruct [
    :chain,
    :method,
    :strategy,
    :protocol,
    :exclude,
    :metrics,
    :timeout,
    :region_filter,
    :prefer_cached
  ]

  @type strategy :: :fastest | :cheapest | :priority | :round_robin
  @type protocol :: :http | :ws | :both

  @type t :: %__MODULE__{
          chain: String.t(),
          method: String.t(),
          strategy: strategy(),
          protocol: protocol(),
          exclude: [String.t()],
          metrics: module(),
          timeout: non_neg_integer(),
          region_filter: String.t() | nil,
          prefer_cached: boolean()
        }

  @doc """
  Creates a new selection context with defaults.

  ## Examples

      iex> SelectionContext.new("ethereum", "eth_blockNumber", strategy: :fastest)
      %SelectionContext{chain: "ethereum", method: "eth_blockNumber", strategy: :fastest, ...}
  """
  @spec new(String.t(), String.t(), keyword()) :: t()
  def new(chain, method, opts \\ []) do
    %__MODULE__{
      chain: chain,
      method: method,
      strategy: Keyword.get(opts, :strategy, :cheapest),
      protocol: Keyword.get(opts, :protocol, :both),
      exclude: Keyword.get(opts, :exclude, []),
      metrics: Keyword.get(opts, :metrics, Lasso.RPC.Metrics),
      timeout: Keyword.get(opts, :timeout, 30_000),
      region_filter: Keyword.get(opts, :region_filter),
      prefer_cached: Keyword.get(opts, :prefer_cached, false)
    }
  end

  @doc """
  Validates that the context has all required fields and valid values.
  """
  @spec validate(t()) :: {:ok, t()} | {:error, String.t()}
  def validate(%__MODULE__{} = ctx) do
    cond do
      is_nil(ctx.chain) or ctx.chain == "" ->
        {:error, "Chain name is required"}

      is_nil(ctx.method) or ctx.method == "" ->
        {:error, "Method name is required"}

      ctx.strategy not in [:fastest, :cheapest, :priority, :round_robin] ->
        {:error, "Invalid strategy: #{inspect(ctx.strategy)}"}

      ctx.protocol not in [:http, :ws, :both] ->
        {:error, "Invalid protocol: #{inspect(ctx.protocol)}"}

      not is_list(ctx.exclude) ->
        {:error, "Exclude must be a list of provider IDs"}

      ctx.timeout <= 0 ->
        {:error, "Timeout must be positive"}

      true ->
        {:ok, ctx}
    end
  end
end
