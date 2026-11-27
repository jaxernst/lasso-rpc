defmodule Lasso.Core.Streaming.Backfill do
  @moduledoc """
  Fetches and reconciles missed blocks and logs for a stream recovery task.
  Delivers replay events through coordinator acknowledgements and returns the covered head.
  """

  require Logger

  alias Lasso.Core.Streaming.Ingress
  alias Lasso.Core.Support.{ContinuityPolicy, GapFiller}

  defmodule Context do
    @moduledoc false
    defstruct [
      :profile,
      :chain_id,
      :max_backfill,
      :backfill_timeout,
      :continuity_policy,
      :allow_head_regression,
      :minimum_head,
      :excluded_providers,
      :plan,
      admission_retries: []
    ]

    @type t :: %__MODULE__{
            profile: String.t(),
            chain_id: pos_integer(),
            max_backfill: non_neg_integer(),
            backfill_timeout: non_neg_integer(),
            continuity_policy: atom(),
            allow_head_regression: boolean(),
            minimum_head: non_neg_integer() | nil,
            excluded_providers: [String.t()],
            admission_retries: [String.t()],
            plan: GapFiller.Plan.t()
          }
  end

  @spec run(
          Context.t(),
          term(),
          non_neg_integer() | nil,
          map(),
          reference(),
          (String.t(), pos_integer(), String.t(), [String.t()] ->
             {:ok, String.t()} | {:error, :no_http_provider})
        ) :: {:ok, non_neg_integer()} | {:error, term()}
  def run(ctx, key, continuity_marker, continuity_snapshot, owner_id, select_retry) do
    execute_backfill(ctx, key, continuity_marker, continuity_snapshot, owner_id, select_retry)
  rescue
    error ->
      Logger.error("Backfill error: #{inspect(error)}",
        chain_id: ctx.chain_id,
        key: inspect(key)
      )

      {:error, {:exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp execute_backfill(ctx, key, continuity_marker, continuity_snapshot, owner_id, select_retry) do
    with {:ok, head} <- fetch_covered_head(ctx, select_retry) do
      result =
        case subscription_key(key) do
          {:newHeads} ->
            backfill_blocks(ctx, key, continuity_marker, continuity_snapshot, owner_id, head)

          {:logs, filter} ->
            backfill_logs(
              ctx,
              key,
              filter,
              continuity_marker,
              continuity_snapshot,
              owner_id,
              head
            )
        end

      with :ok <- result, do: {:ok, head}
    end
  end

  defp backfill_blocks(ctx, key, last, snapshot, owner_id, head) do
    case continuity_range(last, head, ctx.max_backfill, ctx.continuity_policy) do
      {:none} ->
        :ok

      {:regressed, _last_seen, observed_head} ->
        backfill_canonical_blocks(
          ctx,
          snapshot,
          observed_head,
          observed_head,
          owner_id,
          allow_observation_boundary: true
        )

      {:range, from_n, to_n} ->
        backfill_canonical_blocks(ctx, snapshot, from_n, to_n, owner_id,
          allow_observation_boundary: ctx.allow_head_regression
        )

      {:exceeded, from_n, to_n} ->
        Logger.warning("Gap exceeds max_backfill_blocks: #{from_n}-#{to_n}",
          chain_id: ctx.chain_id,
          key: inspect(key)
        )

        if ctx.continuity_policy == :best_effort,
          do:
            backfill_canonical_blocks(ctx, snapshot, from_n, to_n, owner_id,
              allow_observation_boundary: ctx.allow_head_regression
            ),
          else: {:error, :gap_exceeded}
    end
  end

  defp fetch_covered_head(ctx, select_retry) do
    with {:ok, head} <- GapFiller.fetch_head(ctx.plan) do
      cond do
        head >= (ctx.minimum_head || 0) ->
          {:ok, head}

        recovery_remaining_ms(ctx.plan.deadline_us) <= 0 ->
          {:error, :source_behind_observed_head}

        true ->
          case select_retry.(
                 ctx.profile,
                 ctx.chain_id,
                 ctx.plan.provider_id,
                 [ctx.plan.provider_id | ctx.excluded_providers]
               ) do
            {:ok, _provider_id} ->
              {:error, :source_behind_observed_head}

            {:error, :no_http_provider} ->
              Process.sleep(min(100, recovery_remaining_ms(ctx.plan.deadline_us)))
              fetch_covered_head(ctx, select_retry)
          end
      end
    end
  end

  defp backfill_canonical_blocks(ctx, snapshot, from_n, to_n, owner_id, opts) do
    history = Map.get(snapshot, :head_history, %{})
    allow_observation_boundary = Keyword.fetch!(opts, :allow_observation_boundary)

    with {:ok, ancestor, probed} <-
           find_common_ancestor(
             ctx.plan,
             history,
             from_n,
             ctx.max_backfill,
             allow_observation_boundary
           ),
         replay_from = max(ancestor + 1, from_n),
         {:ok, blocks} <- fetch_unprobed_blocks(ctx.plan, probed, replay_from, to_n) do
      blocks =
        blocks
        |> Map.values()
        |> Enum.sort_by(&decode_hex(Map.get(&1, "number", "0x0")))

      with :ok <- validate_canonical_branch(blocks) do
        emit_backfill_events(ctx.plan, owner_id, ctx.plan.provider_id, blocks)
      end
    end
  end

  defp find_common_ancestor(
         plan,
         history,
         from_n,
         max_backfill,
         allow_observation_boundary
       ) do
    lower_bound = max(from_n - max_backfill + 1, 0)

    find_common_ancestor(
      plan,
      history,
      from_n,
      lower_bound,
      %{},
      max_backfill,
      allow_observation_boundary
    )
  end

  defp find_common_ancestor(
         _plan,
         history,
         number,
         lower_bound,
         probed,
         max_backfill,
         allow_observation_boundary
       )
       when number < lower_bound do
    if map_size(history) <= 1 or
         (allow_observation_boundary and
            initial_observation_window?(history, max_backfill)) do
      {:ok, earliest_observed_height(history, lower_bound) - 1, probed}
    else
      {:error, :reorg_horizon_exceeded}
    end
  end

  defp find_common_ancestor(
         plan,
         history,
         number,
         lower_bound,
         probed,
         max_backfill,
         allow_observation_boundary
       ) do
    case Map.fetch(history, number) do
      {:ok, retained} ->
        with {:ok, [canonical]} <- GapFiller.ensure_blocks(plan, number, number) do
          probed = Map.put(probed, number, canonical)

          if Map.get(retained, "hash") == Map.get(canonical, "hash") do
            {:ok, number, probed}
          else
            find_common_ancestor(
              plan,
              history,
              number - 1,
              lower_bound,
              probed,
              max_backfill,
              allow_observation_boundary
            )
          end
        end

      :error ->
        case match_retained_parent(
               plan,
               history,
               number,
               max_backfill,
               allow_observation_boundary
             ) do
          :match ->
            {:ok, number, probed}

          :miss ->
            find_common_ancestor(
              plan,
              history,
              number - 1,
              lower_bound,
              probed,
              max_backfill,
              allow_observation_boundary
            )

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp match_retained_parent(
         plan,
         history,
         number,
         max_backfill,
         allow_observation_boundary
       ) do
    earliest = earliest_observed_height(history, number + 1)

    with false <- allow_observation_boundary,
         true <- map_size(history) > 1,
         true <- number == earliest - 1,
         true <- initial_observation_window?(history, max_backfill),
         %{"parentHash" => parent_hash} when is_binary(parent_hash) <- Map.get(history, earliest),
         {:ok, [canonical]} <- GapFiller.ensure_blocks(plan, number, number) do
      if Map.get(canonical, "hash") == parent_hash, do: :match, else: :miss
    else
      {:error, _reason} = error -> error
      _other -> :miss
    end
  end

  defp initial_observation_window?(history, max_backfill) when map_size(history) < max_backfill do
    heights = history |> Map.keys() |> Enum.sort()

    case heights do
      [] -> false
      [first | _] -> heights == Enum.to_list(first..List.last(heights))
    end
  end

  defp initial_observation_window?(_history, _max_backfill), do: false

  defp earliest_observed_height(history, fallback) do
    history
    |> Map.keys()
    |> Enum.min(fn -> fallback end)
  end

  defp fetch_unprobed_blocks(_plan, probed, from_n, to_n) when from_n > to_n,
    do: {:ok, probed}

  defp fetch_unprobed_blocks(plan, probed, from_n, to_n) do
    Enum.reduce_while(from_n..to_n, {:ok, probed}, fn number, {:ok, blocks} ->
      if Map.has_key?(blocks, number) do
        {:cont, {:ok, blocks}}
      else
        case GapFiller.ensure_blocks(plan, number, number) do
          {:ok, [block]} -> {:cont, {:ok, Map.put(blocks, number, block)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    end)
  end

  defp validate_canonical_branch([]), do: :ok

  defp validate_canonical_branch([first | rest]) do
    with {:ok, first_number, first_hash} <- canonical_header_identity(first) do
      Enum.reduce_while(rest, {:ok, first_number, first_hash}, fn block,
                                                                  {:ok, previous_number,
                                                                   previous_hash} ->
        with {:ok, number, hash} <- canonical_header_identity(block),
             true <- number == previous_number + 1,
             true <- Map.get(block, "parentHash") == previous_hash do
          {:cont, {:ok, number, hash}}
        else
          _ -> {:halt, {:error, :inconsistent_canonical_branch}}
        end
      end)
      |> case do
        {:ok, _number, _hash} -> :ok
        {:error, _reason} = error -> error
      end
    end
  end

  defp canonical_header_identity(block) do
    case {decode_hex(Map.get(block, "number")), Map.get(block, "hash")} do
      {number, hash} when is_integer(number) and is_binary(hash) -> {:ok, number, hash}
      _ -> {:error, :invalid_canonical_header}
    end
  end

  defp backfill_logs(ctx, key, filter, last, snapshot, owner_id, head) do
    with :ok <- ensure_history_complete(snapshot) do
      case continuity_range(last, head, ctx.max_backfill, ctx.continuity_policy) do
        {:none} ->
          :ok

        {:regressed, last_seen, observed_head} ->
          Logger.error("Backfill source head regressed below the delivered stream",
            chain_id: ctx.chain_id,
            key: inspect(key),
            last_seen: last_seen,
            observed_head: observed_head
          )

          {:error, :head_regressed}

        {:range, from_n, to_n} ->
          backfill_log_range(ctx, filter, snapshot, from_n, to_n, owner_id)

        {:exceeded, from_n, to_n} ->
          Logger.warning("Gap exceeds max_backfill_blocks: #{from_n}-#{to_n}",
            chain_id: ctx.chain_id,
            key: inspect(key)
          )

          if ctx.continuity_policy == :strict_abort,
            do: {:error, :gap_exceeded},
            else: backfill_log_range(ctx, filter, snapshot, from_n, to_n, owner_id)
      end
    end
  end

  defp ensure_history_complete(%{history_overflowed: true}), do: {:error, :history_overflow}
  defp ensure_history_complete(_snapshot), do: :ok

  defp backfill_log_range(ctx, filter, snapshot, from_n, to_n, owner_id) do
    provider_id = ctx.plan.provider_id
    retained_logs = Map.get(snapshot, :logs, [])

    with {:ok, orphaned_logs} <- find_orphaned_logs(ctx.plan, retained_logs),
         replay_from <- replay_from_for_logs(orphaned_logs, from_n),
         {:ok, logs} <- GapFiller.ensure_logs(ctx.plan, filter, replay_from, to_n) do
      removals = Enum.map(orphaned_logs, &Map.put(&1, "removed", true))
      emit_backfill_events(ctx.plan, owner_id, provider_id, removals ++ logs)
    end
  end

  defp find_orphaned_logs(plan, retained_logs) do
    retained_logs
    |> Enum.group_by(&decode_hex(Map.get(&1, "blockNumber", "0x0")))
    |> Enum.sort_by(fn {number, _logs} -> number end, :desc)
    |> Enum.reduce_while({:ok, []}, fn {number, logs}, {:ok, orphaned} ->
      case GapFiller.ensure_blocks(plan, number, number) do
        {:ok, [canonical]} ->
          canonical_hash = Map.get(canonical, "hash")
          at_height = Enum.filter(logs, &(Map.get(&1, "blockHash") != canonical_hash))
          {:cont, {:ok, at_height ++ orphaned}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp replay_from_for_logs([], from_n), do: from_n

  defp replay_from_for_logs(orphaned_logs, from_n) do
    orphaned_logs
    |> Enum.map(&decode_hex(Map.get(&1, "blockNumber", "0x0")))
    |> Enum.min()
    |> min(from_n)
  end

  defp emit_backfill_events(plan, owner_id, provider_id, events) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      event_ref = make_ref()

      delivery =
        Ingress.send(
          plan.caller_pid,
          {:backfill_event, owner_id, self(), provider_id, event,
           System.monotonic_time(:millisecond), event_ref}
        )

      if delivery != :ok,
        do: send(self(), {:backfill_event_ack, event_ref, {:error, :ingress_exhausted}})

      receive do
        {:backfill_event_ack, ^event_ref, :ok} ->
          {:cont, :ok}

        {:backfill_event_ack, ^event_ref, {:error, reason}} ->
          {:halt, {:error, reason}}
      after
        max(div(plan.deadline_us - System.monotonic_time(:microsecond) + 999, 1_000), 0) ->
          {:halt, {:error, :backfill_delivery_timeout}}
      end
    end)
  end

  defp continuity_range(last_seen, head, _max_backfill, _policy)
       when is_integer(last_seen) and head < last_seen do
    {:regressed, last_seen, head}
  end

  defp continuity_range(last_seen, head, max_backfill, policy) when is_integer(last_seen) do
    ContinuityPolicy.needed_block_range(last_seen - 1, head, max_backfill + 1, policy)
  end

  defp continuity_range(last_seen, head, max_backfill, policy) do
    ContinuityPolicy.needed_block_range(last_seen, head, max_backfill, policy)
  end

  defp subscription_key({:route, _route, key}), do: key
  defp subscription_key(key), do: key

  defp decode_hex(nil), do: 0
  defp decode_hex("0x" <> rest), do: String.to_integer(rest, 16)
  defp decode_hex(num) when is_integer(num), do: num
  defp decode_hex(_), do: 0

  defp recovery_remaining_ms(deadline_us) do
    max(div(deadline_us - System.monotonic_time(:microsecond) + 999, 1_000), 0)
  end
end
