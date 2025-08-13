defmodule Livechain.Config.MethodPolicy do
  @moduledoc """
  Central source of truth for per-method timeouts and policies.

  Timeouts can be overridden via application config:

      config :livechain, :method_timeouts, %{
        "eth_getLogs" => 60_000,
        "eth_call" => 20_000
      }
  """

  @type method :: String.t()

  @default_timeouts %{
    # Heavy
    "eth_getLogs" => 60_000,
    "eth_getFilterLogs" => 60_000,
    "eth_newFilter" => 30_000,
    "debug_traceTransaction" => 120_000,
    "debug_traceBlock" => 120_000,
    # Medium
    "eth_getBlockByNumber" => 30_000,
    "eth_getBlockByHash" => 30_000,
    "eth_getTransactionByHash" => 20_000,
    "eth_getTransactionReceipt" => 20_000,
    "eth_call" => 20_000,
    "eth_estimateGas" => 20_000,
    # Quick
    "eth_blockNumber" => 10_000,
    "eth_chainId" => 5_000,
    "eth_gasPrice" => 10_000,
    "eth_getBalance" => 15_000,
    "eth_getTransactionCount" => 15_000,
    "eth_getCode" => 15_000,
    "net_version" => 5_000,
    "web3_clientVersion" => 5_000
  }

  @default_fallback 30_000
  @default_max_failovers 1

  @spec timeout_for(method) :: non_neg_integer()
  def timeout_for(method) when is_binary(method) do
    overrides = Application.get_env(:livechain, :method_timeouts, %{})
    Map.get(overrides, method, Map.get(@default_timeouts, method, @default_fallback))
  end

  @spec max_failovers(method) :: non_neg_integer()
  def max_failovers(_method) do
    Application.get_env(:livechain, :max_failovers, @default_max_failovers)
  end
end
