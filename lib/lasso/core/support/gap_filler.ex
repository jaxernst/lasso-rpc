defmodule Lasso.Core.Support.GapFiller do
  @moduledoc """
  HTTP backfill utilities with one immutable route and absolute request budget.
  """

  alias Lasso.Core.Request.ExecutionScope
  alias Lasso.Core.Support.CircuitBreaker.Snapshot
  alias Lasso.Core.Support.{ErrorNormalizer, LogRangeLimit}
  alias Lasso.Core.Transport.UpstreamAdmission
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.JSONRPC.Quantity
  alias Lasso.Providers.Catalog
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
        params = [Quantity.encode(block_number), false]

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
  def ensure_logs(%Plan{} = plan, filter, from_n, to_n),
    do: with_logs(plan, filter, from_n, to_n, &{:ok, &1})

  @doc """
  Fetches the logs of `from_n..to_n` and passes them, in block and log index order, to
  `consume`, returning its result.

  Each log response stays charged to upstream admission until `consume` returns, so the
  caller hands the logs to its own admission before their bytes are released. A range the
  upstream refuses as too wide is fetched as halves, recursively, under the same plan
  deadline and request admission. When the range's last block is missing, this returns
  `{:error, {:range_end_missing, to_n}}` for the caller to take a new head.
  """
  @spec with_logs(Plan.t(), map(), pos_integer(), pos_integer(), (list() -> result)) ::
          result | {:error, term()}
        when result: var
  def with_logs(%Plan{} = plan, filter, from_n, to_n, consume) when from_n <= to_n do
    {result, held} = fetch_logs_range(plan, filter, from_n, to_n)

    try do
      with {:ok, logs} <- result, do: consume.(sort_logs(logs))
    after
      release(
        held,
        if(match?({:ok, _}, result), do: :backfill_handed_off, else: :backfill_discarded)
      )
    end
  end

  def with_logs(%Plan{}, _filter, _from, _to, consume), do: consume.([])

  defp sort_logs(logs) do
    Enum.sort_by(logs, fn log ->
      {decode_hex(Map.get(log, "blockNumber")), decode_hex(Map.get(log, "logIndex"))}
    end)
  end

  defp release(held, reason), do: Enum.each(held, &Response.Success.release_capacity(&1, reason))

  defp fetch_logs_range(plan, filter, from_n, to_n) do
    case fetch_logs(plan, filter, from_n, to_n) do
      {:ok, logs, _bytes, held} ->
        {{:ok, logs}, held}

      {:error, reason} ->
        if from_n < to_n and too_wide?(reason),
          do: fetch_split_logs(plan, filter, from_n, to_n),
          else: {{:error, reason}, []}
    end
  end

  defp too_wide?(%JError{category: :log_range_limit}), do: true
  defp too_wide?(reason), do: LogRangeLimit.plan_range_refusal?(reason)

  # The halves are separate reads of the chain. A reorg inside the range changes the hash of
  # block `to_n`, so only a hash that matches before and after the halves publishes them; a
  # changed hash refetches the whole range.
  defp fetch_split_logs(plan, filter, from_n, to_n) do
    case block_hash(plan, to_n) do
      {:ok, anchor} when is_binary(anchor) ->
        case fetch_halves(plan, filter, from_n, to_n, {0, []}) do
          {:ok, logs, {_bytes, held}} ->
            confirm_anchor(plan, filter, from_n, to_n, anchor, logs, held)

          {:error, :split_response_too_large, {_bytes, held}} ->
            {{:error, response_too_large(plan)}, held}

          {:error, reason, {_bytes, held}} ->
            {{:error, reason}, held}
        end

      {:ok, nil} ->
        {{:error, {:range_end_missing, to_n}}, []}

      {:error, _reason} = error ->
        {error, []}
    end
  end

  defp confirm_anchor(plan, filter, from_n, to_n, anchor, logs, held) do
    case block_hash(plan, to_n) do
      {:ok, ^anchor} ->
        {{:ok, logs}, held}

      {:ok, nil} ->
        {{:error, {:range_end_missing, to_n}}, held}

      {:ok, _changed} ->
        release(held, :backfill_discarded)
        fetch_logs_range(plan, filter, from_n, to_n)

      {:error, _reason} = error ->
        {error, held}
    end
  end

  # The halves together hold no more response bytes than one unsplit response may, and stay
  # charged until the whole range is handed off.
  defp fetch_halves(plan, filter, from_n, to_n, acc) do
    mid = div(from_n + to_n, 2)

    with {:ok, low, acc} <- fetch_range(plan, filter, from_n, mid, acc),
         {:ok, high, acc} <- fetch_range(plan, filter, mid + 1, to_n, acc),
         do: {:ok, low ++ high, acc}
  end

  defp fetch_range(plan, filter, from_n, to_n, {bytes, held} = acc) do
    case fetch_logs(plan, filter, from_n, to_n) do
      {:ok, logs, size, response} ->
        acc = {bytes + size, response ++ held}

        if bytes + size > UpstreamAdmission.response_limit(),
          do: {:error, :split_response_too_large, acc},
          else: {:ok, logs, acc}

      {:error, reason} ->
        if from_n < to_n and too_wide?(reason),
          do: fetch_halves(plan, filter, from_n, to_n, acc),
          else: {:error, reason, acc}
    end
  end

  defp fetch_logs(plan, filter, from_n, to_n) do
    range = %{"fromBlock" => Quantity.encode(from_n), "toBlock" => Quantity.encode(to_n)}

    case held_request(plan, "eth_getLogs", [Map.merge(filter, range)]) do
      {:ok, logs, bytes, held} when is_list(logs) ->
        {:ok, logs, bytes, held}

      {:ok, other, _bytes, held} ->
        release(held, :backfill_discarded)
        {:error, {:invalid_logs_response, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The error the request pipeline returns for one eth_getLogs response over the cap.
  defp response_too_large(plan) do
    {:ok, error} =
      LogRangeLimit.translate(
        "eth_getLogs",
        ErrorNormalizer.normalize({:response_limit, :response_too_large},
          provider_id: plan.provider_id,
          context: :transport,
          transport: :http
        )
      )

    error
  end

  defp block_hash(plan, number) do
    case request(plan, "eth_getBlockByNumber", [Quantity.encode(number), false]) do
      {:ok, %{"hash" => hash}} when is_binary(hash) -> {:ok, hash}
      {:ok, nil} -> {:ok, nil}
      {:ok, other} -> {:error, {:invalid_block_response, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(plan, method, params) do
    with {:ok, result, _bytes, held} <- held_request(plan, method, params) do
      release(held, :backfill_consumed)
      {:ok, result}
    end
  end

  # A decoded result keeps its response lease, returned as `held` for the caller to release,
  # with its size: the raw bytes the transport caps, or the encoded size of a requester's
  # decoded result.
  defp held_request(plan, method, params) do
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
        {:ok, %Response.Success{} = response, _ctx} ->
          case Response.Success.decode_result(response) do
            {:ok, result} ->
              {:ok, result, Response.Success.response_size(response), [response]}

            {:error, _reason} = error ->
              release([response], :backfill_consumed)
              error
          end

        {:ok, result, _ctx} ->
          {:ok, result, result |> Jason.encode_to_iodata!() |> IO.iodata_length(), []}

        {:error, reason, ctx} ->
          reason = Response.Capacity.discard(reason, :backfill_consumed)

          if connection_admission?(plan, ctx),
            do: {:error, {:connection_admission, reason}},
            else: {:error, reason}

        other ->
          {:error, {:unexpected_request_result, other}}
      end
    end
  end

  defp connection_admission?(plan, %{
         terminal_reason: :circuit_open,
         execution_envelope: %{dispatch_count: 0}
       }) do
    instance_id = Catalog.lookup_instance_id(plan.profile, plan.chain_id, plan.provider_id)

    case Snapshot.lookup({instance_id, :http}) do
      {:ok, %{opened_by_category: :connect_failure}} -> true
      {:ok, %{state: :closed}} -> true
      _ -> false
    end
  end

  defp connection_admission?(_plan, _ctx), do: false

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

  defp decode_block_number(value) when is_binary(value) do
    case Quantity.decode(value) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, :invalid_quantity} -> {:error, {:invalid_block_number, value}}
    end
  end

  defp decode_block_number(number) when is_integer(number) and number >= 0, do: {:ok, number}
  defp decode_block_number(other), do: {:error, {:invalid_block_number, other}}

  defp decode_hex(nil), do: nil
  defp decode_hex(num) when is_integer(num), do: num

  defp decode_hex(value) do
    case Quantity.decode(value) do
      {:ok, decoded} -> decoded
      {:error, :invalid_quantity} -> nil
    end
  end
end
