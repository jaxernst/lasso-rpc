defmodule Lasso.RPC.Strategy do
  @moduledoc """
  Behaviour for routing strategies.

  Strategies provide two things:
  - A prepared context via `prepare_context/1` for shared knobs and thresholds
  - A channel ranking via `rank_channels/4`, which orders eligible channels

  Provider selection is derived from channel ranking, so no separate provider
  `choose/3` is required in the unified API.
  """

  alias Lasso.RPC.{Channel, SelectionContext, StrategyContext}

  @type candidate :: %{
          required(:id) => String.t(),
          required(:config) => map(),
          optional(:availability) => :up | :limited | :down | :misconfigured
        }

  @type context :: StrategyContext.t()

  @doc """
  Prepare a strategy-specific context map. Called by the selection pipeline
  prior to invoking `choose/3` so strategies can fetch extra data they need
  (e.g., pool stats, gating thresholds, cached data, etc.).

  Implementations should return a map that will be passed to `choose/3`.
  The `base_ctx` contains common fields like `:chain`, `:now_ms`, `:timeout`.
  """
  @callback prepare_context(selection :: SelectionContext.t()) :: StrategyContext.t()

  @doc """
  Rank eligible channels for a request. Returns the channels ordered from most
  preferred to least preferred.

  The profile parameter enables profile-scoped metrics lookups for routing decisions.
  """
  @callback rank_channels(
              channels :: [Channel.t()],
              method :: String.t(),
              ctx :: context(),
              profile :: String.t(),
              chain :: String.t()
            ) :: [Channel.t()]
end
