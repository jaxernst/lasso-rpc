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
    # Heavy
    "eth_getLogs" => 3_000,
    "eth_getFilterLogs" => 3_000,
    "eth_newFilter" => 3_000,
    "debug_traceTransaction" => 3_000,
    "debug_traceBlock" => 3_000,
    # Medium
    "eth_getBlockByNumber" => 3_000,
    "eth_getBlockByHash" => 3_000,
    "eth_getTransactionByHash" => 3_000,
    "eth_getTransactionReceipt" => 3_000,
    "eth_call" => 3_000,
    "eth_estimateGas" => 3_000,
    # Quick
    "eth_blockNumber" => 1_000,
    "eth_chainId" => 1_000,
    "eth_gasPrice" => 2_000,
    "eth_getBalance" => 3_000,
    "eth_getTransactionCount" => 3_000,
    "eth_getCode" => 3_000,
    "net_version" => 1_000,
    "web3_clientVersion" => 1_000
  }

  @default_fallback 30_000
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
