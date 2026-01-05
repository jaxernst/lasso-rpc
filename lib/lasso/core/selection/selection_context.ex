defmodule Lasso.RPC.SelectionContext do
  @moduledoc """
  Context object for provider selection containing all necessary parameters
  and dependencies for making routing decisions.

  This eliminates parameter passing complexity and provides a clean
  interface for selection strategies.
  """

  @enforce_keys [:profile, :chain, :method]
  defstruct [
    :profile,
    :chain,
    :method,
    :strategy,
    :protocol,
    :exclude,
    :metrics,
    :timeout
  ]

  @type strategy :: :fastest | :cheapest | :priority | :round_robin | :latency_weighted
  @type protocol :: :http | :ws | :both

  @type t :: %__MODULE__{
          profile: String.t(),
          chain: String.t(),
          method: String.t(),
          strategy: strategy(),
          protocol: protocol(),
          exclude: [String.t()],
          metrics: module(),
          timeout: non_neg_integer()
        }

  @doc """
  Creates a new selection context with defaults.

  ## Examples

      iex> SelectionContext.new("default", "ethereum", "eth_blockNumber", strategy: :fastest)
      %SelectionContext{profile: "default", chain: "ethereum", method: "eth_blockNumber", strategy: :fastest, ...}
  """
  @spec new(String.t(), String.t(), String.t(), keyword()) :: t()
  def new(profile, chain, method, opts \\ [])
      when is_binary(profile) and is_binary(chain) and is_binary(method) do
    %__MODULE__{
      profile: profile,
      chain: chain,
      method: method,
      strategy: Keyword.get(opts, :strategy, :cheapest),
      protocol: Keyword.get(opts, :protocol, :both),
      exclude: Keyword.get(opts, :exclude, []),
      metrics: Keyword.get(opts, :metrics, Lasso.Core.Benchmarking.Metrics),
      timeout: Keyword.get(opts, :timeout, 30_000)
    }
  end

  @doc """
  Validates that the context has all required fields and valid values.
  """
  @spec validate(t()) :: {:ok, t()} | {:error, String.t()}
  def validate(%__MODULE__{} = ctx) do
    with :ok <- validate_profile(ctx.profile),
         :ok <- validate_chain(ctx.chain),
         :ok <- validate_method(ctx.method),
         :ok <- validate_strategy(ctx.strategy),
         :ok <- validate_protocol(ctx.protocol),
         :ok <- validate_exclude(ctx.exclude),
         :ok <- validate_timeout(ctx.timeout) do
      {:ok, ctx}
    end
  end

  defp validate_profile(profile) when is_binary(profile) and profile != "", do: :ok
  defp validate_profile(_), do: {:error, "Profile name is required"}

  defp validate_chain(chain) when is_binary(chain) and chain != "", do: :ok
  defp validate_chain(_), do: {:error, "Chain name is required"}

  defp validate_method(method) when is_binary(method) and method != "", do: :ok
  defp validate_method(_), do: {:error, "Method name is required"}

  defp validate_strategy(strategy)
       when strategy in [:fastest, :cheapest, :priority, :round_robin, :latency_weighted],
       do: :ok

  defp validate_strategy(strategy), do: {:error, "Invalid strategy: #{inspect(strategy)}"}

  defp validate_protocol(protocol) when protocol in [:http, :ws, :both], do: :ok
  defp validate_protocol(protocol), do: {:error, "Invalid protocol: #{inspect(protocol)}"}

  defp validate_exclude(exclude) when is_list(exclude), do: :ok
  defp validate_exclude(_), do: {:error, "Exclude must be a list of provider IDs"}

  defp validate_timeout(timeout) when is_integer(timeout) and timeout > 0, do: :ok
  defp validate_timeout(_), do: {:error, "Timeout must be positive"}
end
