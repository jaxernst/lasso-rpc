defmodule Lasso.Config.MethodPolicy do
  @moduledoc """
  Central source of truth for per-method timeouts and policies.

  Timeouts can be overridden via application config:

      config :lasso, :method_timeouts, %{
        "eth_getLogs" => 60_000,
        "eth_call" => 20_000
      }
  """

  @type method :: String.t()

  @default_timeouts %{
    # Ultra-fast (p99 < 500ms)
    "eth_blockNumber" => 1_000,
    "eth_chainId" => 1_000,
    "net_version" => 1_000,
    "web3_clientVersion" => 1_000,
    # Fast state reads (p99 < 1.5s)
    "eth_gasPrice" => 2_000,
    "eth_getBalance" => 2_000,
    "eth_getTransactionCount" => 2_000,
    "eth_getCode" => 2_000,
    "eth_getTransactionByHash" => 2_000,
    "eth_getBlockByNumber" => 2_000,
    "eth_getBlockByHash" => 2_000,
    "eth_getTransactionReceipt" => 3_000,
    # Computational (p99 < 4s)
    "eth_call" => 5_000,
    "eth_estimateGas" => 5_000,
    # Log queries (p99 < 6s for reasonable queries)
    "eth_getLogs" => 5_000,
    "eth_getFilterLogs" => 5_000,
    "eth_newFilter" => 2_000,
    # Debug/trace (legitimately slow - full EVM replay)
    "debug_traceTransaction" => 30_000,
    "debug_traceBlock" => 45_000
  }

  @default_fallback 10_000
  @default_max_failovers 3

  @spec timeout_for(method) :: non_neg_integer()
  def timeout_for(method) when is_binary(method) do
    overrides = Application.get_env(:lasso, :method_timeouts, %{})
    Map.get(overrides, method, Map.get(@default_timeouts, method, @default_fallback))
  end

  @spec max_failovers(method) :: non_neg_integer()
  def max_failovers(_method) do
    Application.get_env(:lasso, :max_failovers, @default_max_failovers)
  end
end
