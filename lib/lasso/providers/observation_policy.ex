defmodule Lasso.Providers.ObservationPolicy do
  @moduledoc "Resolves file-profile observation demand before coalescing physical provider work."

  alias Lasso.BlockSync.Registry
  alias Lasso.Config.{ChainConfig, ConfigStore, ObservationConfig}
  alias Lasso.Providers.Catalog

  @type policy :: %{
          heads: String.t(),
          background_observations: boolean(),
          http_heads_interval_ms: non_neg_integer(),
          http_backup_interval_ms: non_neg_integer(),
          chain_identity_interval_ms: non_neg_integer(),
          evidence_freshness_ms: pos_integer(),
          subscribe_new_heads: boolean()
        }

  @spec references(String.t(), pos_integer(), keyword()) :: [
          {String.t(), ChainConfig.t(), policy()}
        ]
  def references(instance_id, chain_id, opts \\ []) do
    instance_id
    |> Catalog.get_instance_refs()
    |> Enum.flat_map(fn profile ->
      case ConfigStore.get_chain(profile, chain_id) do
        {:ok, chain} ->
          policies_for_reference(profile, chain_id, instance_id, chain, opts)
          |> Enum.map(&{profile, chain, &1})

        _ ->
          []
      end
    end)
  end

  @doc """
  Resolves every provider entry in one profile that shares a physical instance.

  A `standby` entry subscribes to `newHeads` only while it is the profile
  chain's elected standby feed (see `elect_standby/4`).
  """
  @spec policies_for_reference(
          String.t(),
          pos_integer(),
          String.t(),
          ChainConfig.t(),
          keyword()
        ) :: [policy()]
  def policies_for_reference(profile, chain_id, instance_id, chain, opts \\ []) do
    entries = Catalog.get_profile_providers(profile, chain_id)
    provider_ids = for entry <- entries, entry.instance_id == instance_id, do: entry.provider_id

    policies =
      chain.providers
      |> Enum.filter(&(&1.id in provider_ids))
      |> Enum.map(&{&1.id, ObservationConfig.resolve(chain, &1)})

    elected =
      if Enum.any?(policies, fn {_id, policy} -> policy.heads == "standby" end),
        do: elect_standby(chain, entries, System.system_time(:millisecond), opts)

    Enum.map(policies, fn
      {id, %{heads: "standby"} = policy} -> %{policy | subscribe_new_heads: id == elected}
      {_id, policy} -> policy
    end)
  end

  @doc """
  Elects at most one standby provider to hold the chain's `newHeads` feed.

  No standby is elected while any live provider's background feed delivered a
  head within its freshness window. Otherwise the standby whose feed is
  already delivering keeps it, then the lowest priority value, then the
  provider id. A standby whose subscription failed after its last head sits
  out one freshness window so the next standby can take the feed.

  With `:started_at_ms`, a live provider that has reported no WebSocket head
  yet counts as healthy for one freshness window after that time, so a
  restart does not open a standby subscription before the live feed's first
  head.
  """
  @spec elect_standby(ChainConfig.t(), [map()], integer(), keyword()) :: String.t() | nil
  def elect_standby(chain, entries, now_ms, opts \\ []) do
    instances = Map.new(entries, &{&1.provider_id, &1.instance_id})
    started_at_ms = Keyword.get(opts, :started_at_ms)

    feeds =
      Enum.flat_map(chain.providers, fn provider ->
        policy = ObservationConfig.resolve(chain, provider)
        instance = instances[provider.id]

        if is_binary(provider.ws_url) and is_binary(instance) and
             policy.background_observations and policy.heads in ["live", "standby"] do
          [
            %{
              id: provider.id,
              priority: provider.priority,
              heads: policy.heads,
              freshness_ms: policy.evidence_freshness_ms,
              feed: feed_state(chain.chain_id, instance, policy.evidence_freshness_ms, now_ms)
            }
          ]
        else
          []
        end
      end)

    live_healthy? =
      Enum.any?(feeds, fn feed ->
        feed.heads == "live" and
          (feed.feed == :fresh or
             (feed.feed == :none and is_integer(started_at_ms) and
                now_ms - started_at_ms < feed.freshness_ms))
      end)

    unless live_healthy? do
      feeds
      |> Enum.filter(&(&1.heads == "standby" and &1.feed != :failed))
      |> Enum.min_by(&{&1.feed != :fresh, &1.priority, &1.id}, fn -> nil end)
      |> case do
        nil -> nil
        feed -> feed.id
      end
    end
  end

  defp feed_state(chain_id, instance_id, freshness_ms, now_ms) do
    case Registry.get_feed(chain_id, instance_id) do
      nil ->
        :none

      %{head_at_ms: head_at, failed_at_ms: failed_at} ->
        cond do
          is_integer(failed_at) and now_ms - failed_at <= freshness_ms and
              (is_nil(head_at) or failed_at > head_at) ->
            :failed

          is_integer(head_at) and now_ms - head_at <= freshness_ms ->
            :fresh

          is_integer(head_at) or is_integer(failed_at) ->
            :stale

          true ->
            :none
        end
    end
  end

  @spec effective(String.t(), pos_integer(), boolean()) :: map()
  def effective(instance_id, chain_id, has_ws) do
    instance_id
    |> references(chain_id)
    |> Enum.map(&elem(&1, 2))
    |> coalesce(has_ws)
  end

  @spec current_interval([policy()], boolean(), keyword()) :: non_neg_integer()
  def current_interval(policies, has_ws, opts \\ []) do
    age = Keyword.get(opts, :ws_age_ms)

    policies
    |> Enum.filter(& &1.background_observations)
    |> Enum.map(fn policy ->
      healthy? =
        Keyword.get(opts, :ws_healthy?, false) and
          (is_nil(age) or age <= policy.evidence_freshness_ms)

      cond do
        policy.http_heads_interval_ms == 0 -> 0
        has_ws and policy.subscribe_new_heads and healthy? -> policy.http_backup_interval_ms
        true -> policy.http_heads_interval_ms
      end
    end)
    |> minimum()
  end

  @doc "Coalesces per-reference demand; zero means no periodic work."
  @spec coalesce([policy()], boolean()) :: map()
  def coalesce(policies, has_ws) do
    enabled = Enum.filter(policies, & &1.background_observations)

    %{
      enabled?: enabled != [],
      poll_interval_ms: minimum(Enum.map(enabled, & &1.http_heads_interval_ms)),
      ws_active_poll_interval_ms:
        minimum(
          Enum.map(enabled, fn policy ->
            cond do
              policy.http_heads_interval_ms == 0 -> 0
              has_ws and policy.subscribe_new_heads -> policy.http_backup_interval_ms
              true -> policy.http_heads_interval_ms
            end
          end)
        ),
      chain_identity_interval_ms: minimum(Enum.map(enabled, & &1.chain_identity_interval_ms)),
      subscribe_new_heads: has_ws and Enum.any?(enabled, & &1.subscribe_new_heads),
      evidence_freshness_ms: minimum(Enum.map(policies, & &1.evidence_freshness_ms), 60_000)
    }
  end

  defp minimum(values, fallback \\ 0) do
    values |> Enum.filter(&(is_integer(&1) and &1 > 0)) |> Enum.min(fn -> fallback end)
  end
end
