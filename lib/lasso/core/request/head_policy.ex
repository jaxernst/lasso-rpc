defmodule Lasso.RPC.HeadPolicy do
  @moduledoc """
  Opt-in block continuity for choosing a recent block.

  Local choices verify a provider block and atomically advance an instance floor.
  Global choices use BlockPublication admission and a durable fleet publication.
  Explicit block reads retain their selectors. Provider observations do not prove
  canonicality or state availability.
  """

  alias Lasso.BlockPublication.Admission
  alias Lasso.BlockSync.Registry, as: BlockSyncRegistry
  alias Lasso.Config.ConfigStore
  alias Lasso.JSONRPC.{Error, Quantity}
  alias Lasso.Providers.Catalog
  alias Lasso.RPC.{PreparedRequest, RequestContext}
  alias Lasso.RPC.Response.Success

  @table :lasso_accepted_heads
  @max_cas_attempts 8
  @future_tolerance_ms 15_000

  @spec create_table!() :: :ok
  def create_table! do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.insert(
      @table,
      {:generation, Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}
    )

    :ok
  end

  @spec valid_mode?(term()) :: boolean()
  def valid_mode?(mode), do: mode in ["off", "local", "global"]

  @spec acquisition?(String.t(), term()) :: boolean()
  def acquisition?("eth_blockNumber", []), do: true
  def acquisition?("eth_getBlockByNumber", ["latest", full]) when is_boolean(full), do: true
  def acquisition?(_, _), do: false

  @spec initialize(RequestContext.t()) :: RequestContext.t()
  def initialize(ctx) do
    if ctx.opts.request_origin == :client and acquisition?(ctx.method, ctx.params) do
      case ConfigStore.get_chain(ctx.opts.profile, ctx.chain_id) do
        {:ok, %{head_policy: mode} = chain} when mode in ["local", "global"] ->
          block_time =
            if is_integer(chain.block_time_ms) and chain.block_time_ms > 0,
              do: chain.block_time_ms,
              else: 12_000

          %{
            ctx
            | head_policy: %{
                key: {ctx.opts.profile, ctx.chain_id},
                mode: mode,
                max_head_age_ms: max(60_000, 4 * block_time),
                target: nil,
                minimum_height: nil,
                reference_height: nil,
                last_error: nil,
                evidence: nil
              }
          }

        _ ->
          ctx
      end
    else
      ctx
    end
  end

  @spec selection_request(RequestContext.t()) :: {String.t(), list() | map()}
  def selection_request(%{head_policy: nil} = ctx), do: {ctx.method, ctx.params}

  def selection_request(%{head_policy: %{mode: "global"}} = ctx),
    do: Admission.selection_request(ctx)

  def selection_request(ctx) do
    full = if ctx.method == "eth_getBlockByNumber", do: Enum.at(ctx.params, 1), else: false
    {"eth_getBlockByNumber", ["latest", full]}
  end

  @spec prepare_attempt(RequestContext.t()) :: RequestContext.t()
  def prepare_attempt(%{head_policy: nil} = ctx), do: ctx

  def prepare_attempt(%{head_policy: %{mode: "global"}} = ctx),
    do: Admission.prepare_attempt(ctx)

  def prepare_attempt(ctx) do
    policy = ctx.head_policy
    floor = floor_height(policy.key)
    reference = reference_height(ctx.opts.profile, ctx.chain_id)
    minimum = Enum.max(Enum.filter([floor, reference], &is_integer/1), fn -> nil end)
    target = if is_nil(policy.last_error), do: nil, else: minimum
    full = if ctx.method == "eth_getBlockByNumber", do: Enum.at(ctx.params, 1), else: false

    request = %{
      ctx.rpc_request
      | "method" => "eth_getBlockByNumber",
        "params" => [if(is_integer(target), do: Quantity.encode(target), else: "latest"), full]
    }

    {:ok, prepared} = PreparedRequest.new(request, ctx.prepared_request.transport_id)

    %{
      ctx
      | prepared_request: prepared,
        head_policy: %{
          policy
          | target: target,
            minimum_height: minimum,
            reference_height: reference
        }
    }
  end

  @spec accept(Success.t(), RequestContext.t()) ::
          {:ok, Success.t(), RequestContext.t()}
          | {:retry, Error.t(), RequestContext.t()}
          | {:error, Error.t(), RequestContext.t()}
  def accept(result, %{head_policy: %{mode: "global"}} = ctx),
    do: Admission.accept(result, ctx)

  def accept(result, ctx) do
    if Admission.guarded?(ctx) do
      {:error, Admission.error(:publication_changing), ctx}
    else
      accept_local(result, ctx)
    end
  end

  defp accept_local(result, %{head_policy: nil} = ctx), do: {:ok, result, ctx}

  defp accept_local(%Success{} = response, ctx) do
    policy = ctx.head_policy
    now = System.system_time(:millisecond)

    with {:ok, %{"number" => number, "timestamp" => timestamp, "hash" => hash} = header} <-
           Success.decode_result(response),
         {:ok, height} <- Quantity.decode(number),
         {:ok, timestamp} <- Quantity.decode(timestamp),
         true <- valid_hash?(hash),
         :ok <- validate_target(height, policy.target),
         :ok <- validate_minimum(height, policy.minimum_height),
         :ok <- validate_age(timestamp * 1_000, now, policy.max_head_age_ms),
         :ok <- advance(policy.key, height, hash, @max_cas_attempts) do
      evidence = %{
        policy: "local",
        scope: "profile_chain_instance",
        instance: Lasso.Cluster.Topology.self_node_id(),
        generation: generation(),
        block_number: number,
        block_hash: hash,
        block_age_ms: max(0, now - timestamp * 1_000),
        max_head_age_ms: policy.max_head_age_ms,
        reference_height: policy.reference_height,
        upstream_method: "eth_getBlockByNumber"
      }

      result =
        if ctx.method == "eth_blockNumber" do
          %{
            response
            | raw_bytes:
                Jason.encode!(%{
                  "jsonrpc" => response.jsonrpc,
                  "id" => response.id,
                  "result" => header["number"]
                })
          }
        else
          response
        end

      {:ok, result, %{ctx | head_policy: %{policy | evidence: evidence, last_error: nil}}}
    else
      {:error, reason} -> reject(ctx, reason)
      _ -> reject(ctx, :invalid_head_response)
    end
  end

  @spec metadata(RequestContext.t()) :: map() | nil
  def metadata(%{head_policy: %{evidence: evidence}}), do: evidence
  def metadata(_), do: nil

  defp reject(ctx, reason) do
    policy = ctx.head_policy

    error =
      Error.new(-32_001, "Head policy could not establish an eligible block",
        category: :block_not_available,
        retriable?: true,
        breaker_penalty?: false,
        data: %{
          policy: "local",
          scope: "profile_chain_instance",
          reason: bounded_reason(reason),
          minimum_height: floor_height(policy.key),
          target_height: policy.target,
          max_head_age_ms: policy.max_head_age_ms
        }
      )

    {:retry, error, %{ctx | head_policy: %{policy | last_error: error}}}
  end

  defp bounded_reason(reason)
       when reason in [
              :invalid_head_response,
              :target_mismatch,
              :head_too_old,
              :head_in_future,
              :head_regression,
              :block_hash_changed,
              :floor_unavailable,
              :floor_contention
            ],
       do: Atom.to_string(reason)

  defp bounded_reason(_), do: "invalid_head_response"

  defp valid_hash?(hash) when is_binary(hash), do: Regex.match?(~r/\A0x[0-9a-fA-F]{64}\z/, hash)
  defp valid_hash?(_), do: false
  defp validate_target(_height, nil), do: :ok
  defp validate_target(height, height), do: :ok
  defp validate_target(_, _), do: {:error, :target_mismatch}

  defp validate_minimum(_height, nil), do: :ok
  defp validate_minimum(height, minimum) when height >= minimum, do: :ok
  defp validate_minimum(_, _), do: {:error, :head_regression}

  defp validate_age(timestamp, now, max_age) do
    cond do
      timestamp > now + @future_tolerance_ms -> {:error, :head_in_future}
      now - timestamp > max_age -> {:error, :head_too_old}
      true -> :ok
    end
  end

  defp advance(_key, _height, _hash, 0), do: {:error, :floor_contention}

  defp advance(key, height, hash, attempts) do
    hash = String.downcase(hash)

    case :ets.lookup(@table, key) do
      [{^key, :fenced, _}] ->
        {:error, :floor_unavailable}

      [{^key, floor, _}] when height < floor ->
        {:error, :head_regression}

      [{^key, ^height, previous_hash}] when hash != previous_hash ->
        {:error, :block_hash_changed}

      [{^key, ^height, ^hash}] ->
        :ok

      [{^key, _, _} = previous] ->
        case :ets.select_replace(@table, [{previous, [], [{:const, {key, height, hash}}]}]) do
          1 -> :ok
          0 -> advance(key, height, hash, attempts - 1)
        end

      [] ->
        if :ets.insert_new(@table, {key, height, hash}),
          do: :ok,
          else: advance(key, height, hash, attempts - 1)
    end
  rescue
    ArgumentError -> {:error, :floor_unavailable}
  end

  defp floor_height(key) do
    case :ets.lookup(@table, key) do
      [{^key, :fenced, height}] -> height
      [{^key, height, _}] -> height
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Atomically closes the local floor and returns its last accepted height."
  @spec fence_local({String.t(), pos_integer()}) :: non_neg_integer() | nil
  def fence_local(key) do
    case :ets.lookup(@table, key) do
      [{^key, :fenced, height}] ->
        height

      [{^key, height, _} = old] ->
        case :ets.select_replace(@table, [{old, [], [{:const, {key, :fenced, height}}]}]) do
          1 -> height
          0 -> fence_local(key)
        end

      [] ->
        if :ets.insert_new(@table, {key, :fenced, nil}), do: nil, else: fence_local(key)
    end
  end

  @doc "Restores local policy admission after the fleet finishes disabling."
  @spec release_local({String.t(), pos_integer()}, map() | nil) :: :ok | true | non_neg_integer()
  def release_local(key, published) do
    case :ets.lookup(@table, key) do
      [{^key, :fenced, _} = old] ->
        if published do
          :ets.select_replace(@table, [
            {old, [], [{:const, {key, published["height"], published["hash"]}}]}
          ])
        else
          :ets.delete_object(@table, old)
        end

      _ ->
        :ok
    end
  end

  defp generation do
    :ets.lookup_element(@table, :generation, 2)
  end

  defp reference_height(profile, chain_id) do
    with %{} = snapshot <- Catalog.snapshot(),
         {:ok, plan} <- Catalog.get_routing_plan(snapshot, profile, chain_id),
         {:ok, height} <-
           BlockSyncRegistry.get_consensus_height_filtered(
             chain_id,
             Enum.map(plan.providers, & &1.instance_id)
           ) do
      height
    else
      _ -> nil
    end
  end
end
