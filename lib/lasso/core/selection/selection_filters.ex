defmodule Lasso.RPC.SelectionFilters do
  @moduledoc """
  Type-safe filter parameters for provider selection.

  Encapsulates the filtering criteria shared by CandidateListing and Selection.
  """

  @type protocol :: :http | :ws | :both | nil
  @type circuit_state_filter :: :closed | :half_open | :open

  alias Lasso.Observations.HeadSnapshot
  alias Lasso.RPC.{RequestAnalysis, RequestFacts}
  alias Lasso.RPC.RoutingEvidence.Workload

  @type t :: %__MODULE__{
          protocol: protocol(),
          method: String.t() | nil,
          exclude: [String.t()],
          include_half_open: boolean(),
          exclude_rate_limited: boolean(),
          max_lag_blocks: non_neg_integer() | nil,
          requires_archival: boolean(),
          historical_resource: Lasso.RPC.HistoricalCoverage.resource(),
          historical_height: non_neg_integer() | nil,
          reference_height: non_neg_integer() | nil,
          request_facts: Lasso.RPC.RequestFacts.t() | nil,
          head_suitability: Lasso.RPC.Selection.HeadSuitability.t() | nil,
          requires_subscribe_new_heads: boolean(),
          workload_key: Lasso.RPC.RoutingEvidence.Workload.t()
        }

  defstruct protocol: nil,
            method: nil,
            exclude: [],
            include_half_open: false,
            exclude_rate_limited: false,
            max_lag_blocks: nil,
            head_snapshot: nil,
            min_block: nil,
            requires_archival: false,
            historical_resource: nil,
            historical_height: nil,
            # The phase's single head reading: the archive reference height
            # that set archival permission and the request facts captured at
            # the same instant. Candidate eligibility never reads them, so
            # to_map/1 and from_map/1 omit them.
            reference_height: nil,
            request_facts: nil,
            head_suitability: nil,
            requires_subscribe_new_heads: false,
            workload_key: :client

  @doc """
  Creates a new SelectionFilters struct with validated defaults.

  ## Options

    * `:protocol` - Transport protocol filter (:http, :ws, :both, or nil for any)
    * `:method` - Requested method for capability-aware head eligibility
    * `:exclude` - List of provider IDs to exclude
    * `:include_half_open` - Include half-open circuit breaker providers (default: false)
    * `:exclude_rate_limited` - Exclude rate-limited providers (default: false)
    * `:max_lag_blocks` - Maximum acceptable block lag (nil = no limit)
    * `:requires_archival` - Request requires archival data support (default: false)
    * `:requires_subscribe_new_heads` - Request is an `eth_subscribe newHeads`
      and excludes providers with current explicit rejection evidence (default: false)

  ## Examples

      iex> SelectionFilters.new(protocol: :http, max_lag_blocks: 5)
      %SelectionFilters{protocol: :http, max_lag_blocks: 5, ...}

      iex> SelectionFilters.new(requires_archival: true)
      %SelectionFilters{requires_archival: true, ...}
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      protocol: normalize_protocol(Keyword.get(opts, :protocol)),
      method: Keyword.get(opts, :method),
      exclude: Keyword.get(opts, :exclude, []) |> List.wrap(),
      include_half_open: Keyword.get(opts, :include_half_open, false),
      exclude_rate_limited: Keyword.get(opts, :exclude_rate_limited, false),
      max_lag_blocks: Keyword.get(opts, :max_lag_blocks),
      head_snapshot: Keyword.get(opts, :head_snapshot),
      min_block: Keyword.get(opts, :min_block),
      requires_archival: Keyword.get(opts, :requires_archival, false),
      historical_resource: Keyword.get(opts, :historical_resource),
      historical_height: Keyword.get(opts, :historical_height),
      reference_height: Keyword.get(opts, :reference_height),
      request_facts: Keyword.get(opts, :request_facts),
      head_suitability: Keyword.get(opts, :head_suitability),
      requires_subscribe_new_heads: Keyword.get(opts, :requires_subscribe_new_heads, false),
      workload_key: Workload.normalize(Keyword.get(opts, :workload_key, :client))
    }
  end

  @doc """
  Filters for one selection phase.

  One clock reading, `:now_ms` in `selection_opts` or the current time, yields
  one archive reference height. Archival permission comes from that height,
  and the phase's request facts and head suitability are captured at the same instant, so every
  reader of the phase agrees on whether the head was usable. `filter_opts`
  carries the caller's routing filters, as for `new/1`.
  """
  @spec for_phase(
          Lasso.RPC.RoutingPlan.t(),
          String.t(),
          HeadSnapshot.t() | :unavailable,
          keyword(),
          keyword()
        ) :: t()
  def for_phase(plan, method, head_snapshot, selection_opts, filter_opts) do
    now_ms = Keyword.get_lazy(selection_opts, :now_ms, fn -> System.system_time(:millisecond) end)
    params = Keyword.get(selection_opts, :params, [])

    block_facts =
      Keyword.get_lazy(selection_opts, :block_facts, fn ->
        RequestAnalysis.block_facts(method, params)
      end)

    reference_height = HeadSnapshot.archive_reference_height(head_snapshot, now_ms)

    requirements =
      RequestAnalysis.analyze(method, params,
        consensus_height: reference_height,
        archival_threshold: plan.archival_threshold
      )

    filter_opts
    |> Keyword.merge(
      method: method,
      max_lag_blocks: plan.max_lag_blocks,
      head_snapshot: head_snapshot,
      requires_archival: requirements.requires_archival,
      historical_resource: requirements.historical_resource,
      historical_height: requirements.historical_height,
      reference_height: reference_height,
      head_suitability:
        recovery_suitability(
          plan,
          method,
          block_facts,
          head_snapshot,
          now_ms,
          Keyword.get(selection_opts, :preferred_head_height)
        ),
      request_facts:
        RequestFacts.capture(
          plan,
          method,
          block_facts,
          head_snapshot,
          now_ms
        )
    )
    |> new()
  end

  defp recovery_suitability(plan, method, block_facts, snapshot, now_ms, height)
       when is_integer(height),
       do:
         Lasso.RPC.Selection.HeadSuitability.capture(
           plan,
           method,
           block_facts,
           height,
           snapshot,
           now_ms
         )

  defp recovery_suitability(_plan, _method, _block_facts, _snapshot, _now_ms, _height), do: nil

  @doc """
  Creates SelectionFilters from a raw map (for backward compatibility).

  Normalizes keys and values to ensure consistent struct state.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      protocol: normalize_protocol(map[:protocol] || Map.get(map, "protocol")),
      method: map[:method] || Map.get(map, "method"),
      exclude: normalize_exclude(map[:exclude] || Map.get(map, "exclude")),
      include_half_open: to_boolean(map[:include_half_open] || Map.get(map, "include_half_open")),
      exclude_rate_limited:
        to_boolean(map[:exclude_rate_limited] || Map.get(map, "exclude_rate_limited")),
      max_lag_blocks: map[:max_lag_blocks] || Map.get(map, "max_lag_blocks"),
      head_snapshot: map[:head_snapshot],
      min_block: map[:min_block],
      requires_archival: to_boolean(map[:requires_archival] || Map.get(map, "requires_archival")),
      historical_resource: map[:historical_resource] || Map.get(map, "historical_resource"),
      historical_height: map[:historical_height] || Map.get(map, "historical_height"),
      requires_subscribe_new_heads:
        to_boolean(
          map[:requires_subscribe_new_heads] || Map.get(map, "requires_subscribe_new_heads")
        ),
      workload_key: Workload.normalize(map[:workload_key] || Map.get(map, "workload_key"))
    }
  end

  @doc """
  Converts the filters struct to CandidateListing's internal map representation.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = filters) do
    %{
      protocol: filters.protocol,
      method: filters.method,
      exclude: filters.exclude,
      include_half_open: filters.include_half_open,
      exclude_rate_limited: filters.exclude_rate_limited,
      max_lag_blocks: filters.max_lag_blocks,
      head_snapshot: filters.head_snapshot,
      min_block: filters.min_block,
      requires_archival: filters.requires_archival,
      historical_resource: filters.historical_resource,
      historical_height: filters.historical_height,
      requires_subscribe_new_heads: filters.requires_subscribe_new_heads,
      workload_key: filters.workload_key
    }
  end

  defp normalize_protocol(:http), do: :http
  defp normalize_protocol(:ws), do: :ws
  defp normalize_protocol(:both), do: :both
  defp normalize_protocol("http"), do: :http
  defp normalize_protocol("ws"), do: :ws
  defp normalize_protocol("both"), do: :both
  defp normalize_protocol(_), do: nil

  defp normalize_exclude(nil), do: []
  defp normalize_exclude(list) when is_list(list), do: list
  defp normalize_exclude(id) when is_binary(id), do: [id]
  defp normalize_exclude(_), do: []

  defp to_boolean(true), do: true
  defp to_boolean("true"), do: true
  defp to_boolean(1), do: true
  defp to_boolean(_), do: false
end
