defmodule Lasso.RPC.SelectionFilters do
  @moduledoc """
  Type-safe filter parameters for provider selection.

  Encapsulates all filtering criteria used by CandidateListing.list_candidates/3
  and Selection module to ensure consistent handling across the codebase.
  """

  @type protocol :: :http | :ws | :both | nil
  @type circuit_state_filter :: :closed | :half_open | :open

  @type t :: %__MODULE__{
          protocol: protocol(),
          exclude: [String.t()],
          include_half_open: boolean(),
          exclude_rate_limited: boolean(),
          max_lag_blocks: non_neg_integer() | nil,
          min_block: non_neg_integer() | nil,
          requires_archival: boolean(),
          requires_subscribe_new_heads: boolean()
        }

  defstruct protocol: nil,
            exclude: [],
            include_half_open: false,
            exclude_rate_limited: false,
            max_lag_blocks: nil,
            min_block: nil,
            requires_archival: false,
            requires_subscribe_new_heads: false

  @doc """
  Creates a new SelectionFilters struct with validated defaults.

  ## Options

    * `:protocol` - Transport protocol filter (:http, :ws, :both, or nil for any)
    * `:exclude` - List of provider IDs to exclude
    * `:include_half_open` - Include half-open circuit breaker providers (default: false)
    * `:exclude_rate_limited` - Exclude rate-limited providers (default: false)
    * `:max_lag_blocks` - Maximum acceptable block lag (nil = no limit)
    * `:min_block` - Minimum block height the provider must have (nil = no filter)
    * `:requires_archival` - Request requires archival data support (default: false)
    * `:requires_subscribe_new_heads` - Request is an `eth_subscribe newHeads`
      and must route only to providers that declare the capability (default: false)

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
      exclude: Keyword.get(opts, :exclude, []) |> List.wrap(),
      include_half_open: Keyword.get(opts, :include_half_open, false),
      exclude_rate_limited: Keyword.get(opts, :exclude_rate_limited, false),
      max_lag_blocks: Keyword.get(opts, :max_lag_blocks),
      min_block: Keyword.get(opts, :min_block),
      requires_archival: Keyword.get(opts, :requires_archival, false),
      requires_subscribe_new_heads: Keyword.get(opts, :requires_subscribe_new_heads, false)
    }
  end

  @doc """
  Creates SelectionFilters from a raw map (for backward compatibility).

  Normalizes keys and values to ensure consistent struct state.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      protocol: normalize_protocol(map[:protocol] || Map.get(map, "protocol")),
      exclude: normalize_exclude(map[:exclude] || Map.get(map, "exclude")),
      include_half_open: to_boolean(map[:include_half_open] || Map.get(map, "include_half_open")),
      exclude_rate_limited:
        to_boolean(map[:exclude_rate_limited] || Map.get(map, "exclude_rate_limited")),
      max_lag_blocks: map[:max_lag_blocks] || Map.get(map, "max_lag_blocks"),
      min_block: map[:min_block] || Map.get(map, "min_block"),
      requires_archival: to_boolean(map[:requires_archival] || Map.get(map, "requires_archival")),
      requires_subscribe_new_heads:
        to_boolean(
          map[:requires_subscribe_new_heads] || Map.get(map, "requires_subscribe_new_heads")
        )
    }
  end

  @doc """
  Converts the filters struct to a map for CandidateListing compatibility.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = filters) do
    %{
      protocol: filters.protocol,
      exclude: filters.exclude,
      include_half_open: filters.include_half_open,
      exclude_rate_limited: filters.exclude_rate_limited,
      max_lag_blocks: filters.max_lag_blocks,
      min_block: filters.min_block,
      requires_archival: filters.requires_archival,
      requires_subscribe_new_heads: filters.requires_subscribe_new_heads
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
