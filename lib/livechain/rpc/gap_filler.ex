defmodule Livechain.RPC.GapFiller do
  @moduledoc """
  HTTP backfill utilities. Pure API with no GenServer; run in Task from callers.
  """

  alias Livechain.RPC.RequestPipeline

  @type backfill_opts :: [timeout_ms: non_neg_integer()]

  @spec ensure_blocks(String.t(), String.t(), pos_integer(), pos_integer(), backfill_opts) ::
          {:ok, list()} | {:error, term()}
  def ensure_blocks(chain, provider_id, from_n, to_n, _opts \\ [])

  def ensure_blocks(chain, provider_id, from_n, to_n, _opts) when from_n <= to_n do
    blocks =
      Enum.reduce(from_n..to_n, [], fn n, acc ->
        case RequestPipeline.execute_via_channels(
               chain,
               "eth_getBlockByNumber",
               [
                 "0x" <> Integer.to_string(n, 16),
                 false
               ],
               strategy: :priority,
               provider_override: provider_id,
               failover_on_override: false
             ) do
          {:ok, %{"number" => _} = block} -> acc ++ [block]
          _ -> acc
        end
      end)

    :telemetry.execute([:livechain, :subs, :backfill, :block], %{count: length(blocks)}, %{
      chain: chain,
      from: from_n,
      to: to_n,
      provider_id: provider_id
    })

    {:ok, blocks}
  end

  def ensure_blocks(_chain, _provider_id, _from, _to, _opts), do: {:ok, []}

  @spec ensure_logs(String.t(), String.t(), map(), pos_integer(), pos_integer(), backfill_opts) ::
          {:ok, list()} | {:error, term()}
  def ensure_logs(chain, provider_id, filter, from_n, to_n, _opts \\ [])

  def ensure_logs(chain, provider_id, filter, from_n, to_n, _opts) when from_n <= to_n do
    base_filter = %{
      "fromBlock" => "0x" <> Integer.to_string(from_n, 16),
      "toBlock" => "0x" <> Integer.to_string(to_n, 16)
    }

    full_filter = Map.merge(filter, base_filter)

    case RequestPipeline.execute_via_channels(chain, "eth_getLogs", [full_filter],
           strategy: :priority,
           provider_override: provider_id,
           failover_on_override: false
         ) do
      {:ok, logs} when is_list(logs) ->
        ordered =
          Enum.sort_by(logs, fn log ->
            {decode_hex(Map.get(log, "blockNumber")), decode_hex(Map.get(log, "logIndex"))}
          end)

        :telemetry.execute([:livechain, :subs, :backfill, :logs], %{count: length(ordered)}, %{
          chain: chain,
          from: from_n,
          to: to_n,
          provider_id: provider_id
        })

        {:ok, ordered}

      other ->
        {:error, other}
    end
  end

  def ensure_logs(_chain, _provider_id, _filter, _from, _to, _opts), do: {:ok, []}

  defp decode_hex(nil), do: nil
  defp decode_hex("0x" <> rest), do: String.to_integer(rest, 16)
  defp decode_hex(num) when is_integer(num), do: num
end
