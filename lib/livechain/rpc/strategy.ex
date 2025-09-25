defmodule Livechain.RPC.Strategy do
  @moduledoc """
  Behaviour for provider selection strategies.

  Strategies receive a list of provider candidate structs (as produced by the
  ProviderPool) and return the selected provider id or nil if no candidates.
  """

  alias Livechain.RPC.{SelectionContext, StrategyContext}

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

  @callback choose(candidates :: [candidate], method :: String.t() | nil, ctx :: context()) ::
              String.t() | nil
end
