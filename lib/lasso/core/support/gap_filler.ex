defmodule Lasso.Core.Support.GapFiller do
  @moduledoc """
  HTTP backfill utilities with one immutable route and absolute request budget.
  """

  alias Lasso.Core.Request.ExecutionScope
  alias Lasso.RPC.{RequestOptions, RequestPipeline, Response}

  defmodule Plan do
    @moduledoc false

    @enforce_keys [
      :profile,
      :chain_id,
      :provider_id,
      :caller_pid,
      :started_at_us,
      :deadline_us,
      :requester
    ]
    defstruct @enforce_keys

    @type requester ::
            (ExecutionScope.t(), pos_integer(), String.t(), list(), RequestOptions.t() -> term())

    @type t :: %__MODULE__{
            profile: String.t(),
            chain_id: pos_integer(),
            provider_id: String.t(),
            caller_pid: pid(),
            started_at_us: integer(),
            deadline_us: integer(),
            requester: requester()
          }

    @spec new(String.t(), pos_integer(), String.t(), pid(), non_neg_integer(), keyword()) :: t()
    def new(profile, chain_id, provider_id, caller_pid, timeout_ms, opts \\ [])
        when is_binary(profile) and is_integer(chain_id) and chain_id > 0 and
               is_binary(provider_id) and is_pid(caller_pid) and is_integer(timeout_ms) and
               timeout_ms >= 0 do
      started_at_us = Keyword.get(opts, :started_at_us, System.monotonic_time(:microsecond))
      deadline_us = Keyword.get(opts, :deadline_us) || started_at_us + timeout_ms * 1_000

      %__MODULE__{
        profile: profile,
        chain_id: chain_id,
        provider_id: provider_id,
        caller_pid: caller_pid,
        started_at_us: started_at_us,
        deadline_us: deadline_us,
        requester: Keyword.get(opts, :requester, &RequestPipeline.execute_owned/5)
      }
    end
  end

  @type backfill_opts :: [
          timeout_ms: non_neg_integer(),
          profile: String.t(),
          caller_pid: pid(),
          deadline_us: integer(),
          requester: Plan.requester()
        ]

  @spec fetch_head(Plan.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def fetch_head(%Plan{} = plan) do
    with {:ok, result} <- request(plan, "eth_blockNumber", []),
         do: decode_block_number(result)
  end

  @spec ensure_blocks(pos_integer(), String.t(), pos_integer(), pos_integer(), backfill_opts()) ::
          {:ok, list()} | {:error, term()}
  def ensure_blocks(chain_id, provider_id, from_n, to_n, opts \\ []) do
    plan = plan_from_opts(chain_id, provider_id, opts)
    ensure_blocks(plan, from_n, to_n)
  end

  @spec ensure_blocks(Plan.t(), pos_integer(), pos_integer()) ::
          {:ok, list()} | {:error, term()}
  def ensure_blocks(%Plan{} = plan, from_n, to_n) when from_n <= to_n do
    result =
      Enum.reduce_while(from_n..to_n, {:ok, []}, fn block_number, {:ok, blocks} ->
        params = ["0x" <> Integer.to_string(block_number, 16), false]

        case request(plan, "eth_getBlockByNumber", params) do
          {:ok, %{"number" => _} = block} -> {:cont, {:ok, [block | blocks]}}
          {:ok, other} -> {:halt, {:error, {:invalid_block_response, other}}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, reversed} ->
        {:ok, Enum.reverse(reversed)}

      {:error, _reason} = error ->
        error
    end
  end

  def ensure_blocks(%Plan{}, _from, _to), do: {:ok, []}

  @spec ensure_logs(
          pos_integer(),
          String.t(),
          map(),
          pos_integer(),
          pos_integer(),
          backfill_opts()
        ) :: {:ok, list()} | {:error, term()}
  def ensure_logs(chain_id, provider_id, filter, from_n, to_n, opts \\ []) do
    plan = plan_from_opts(chain_id, provider_id, opts)
    ensure_logs(plan, filter, from_n, to_n)
  end

  @spec ensure_logs(Plan.t(), map(), pos_integer(), pos_integer()) ::
          {:ok, list()} | {:error, term()}
  def ensure_logs(%Plan{} = plan, filter, from_n, to_n) when from_n <= to_n do
    full_filter =
      Map.merge(filter, %{
        "fromBlock" => "0x" <> Integer.to_string(from_n, 16),
        "toBlock" => "0x" <> Integer.to_string(to_n, 16)
      })

    case request(plan, "eth_getLogs", [full_filter]) do
      {:ok, logs} when is_list(logs) ->
        ordered =
          Enum.sort_by(logs, fn log ->
            {decode_hex(Map.get(log, "blockNumber")), decode_hex(Map.get(log, "logIndex"))}
          end)

        {:ok, ordered}

      {:ok, other} ->
        {:error, {:invalid_logs_response, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def ensure_logs(%Plan{}, _filter, _from, _to), do: {:ok, []}

  defp request(plan, method, params) do
    with {:ok, timeout_ms} <- remaining_timeout_ms(plan.deadline_us),
         true <- Process.alive?(plan.caller_pid) or {:error, :caller_abandoned} do
      scope =
        if plan.caller_pid == self(),
          do: ExecutionScope.local(self(), plan.deadline_us),
          else: ExecutionScope.monitored(self(), plan.caller_pid, plan.deadline_us)

      opts = %RequestOptions{
        profile: plan.profile,
        strategy: :priority,
        provider_override: plan.provider_id,
        transport: :http,
        failover_on_override: false,
        timeout_ms: timeout_ms,
        request_origin: :system,
        request_id:
          "backfill:#{plan.started_at_us}:#{System.unique_integer([:positive, :monotonic])}"
      }

      case plan.requester.(scope, plan.chain_id, method, params, opts) do
        {:ok, %Response.Success{} = response, _ctx} -> Response.Success.decode_result(response)
        {:ok, result, _ctx} -> {:ok, result}
        {:error, reason, _ctx} -> {:error, reason}
        other -> {:error, {:unexpected_request_result, other}}
      end
    end
  end

  defp remaining_timeout_ms(deadline_us) do
    case div(deadline_us - System.monotonic_time(:microsecond), 1_000) do
      remaining when remaining > 0 -> {:ok, remaining}
      _expired -> {:error, :deadline_exhausted}
    end
  end

  defp plan_from_opts(chain_id, provider_id, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)
    profile = Keyword.get(opts, :profile, "public")
    caller_pid = Keyword.get(opts, :caller_pid, self())

    Plan.new(profile, chain_id, provider_id, caller_pid, timeout_ms,
      deadline_us: Keyword.get(opts, :deadline_us),
      requester: Keyword.get(opts, :requester, &RequestPipeline.execute_owned/5)
    )
  end

  defp decode_block_number("0x" <> hex), do: {:ok, String.to_integer(hex, 16)}
  defp decode_block_number(number) when is_integer(number) and number >= 0, do: {:ok, number}
  defp decode_block_number(other), do: {:error, {:invalid_block_number, other}}

  defp decode_hex(nil), do: nil
  defp decode_hex("0x" <> rest), do: String.to_integer(rest, 16)
  defp decode_hex(num) when is_integer(num), do: num
end
