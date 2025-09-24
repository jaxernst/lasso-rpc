defmodule Livechain.RPC.Strategy do
  @moduledoc """
  Behaviour for provider selection strategies.

  Strategies receive a list of provider candidate structs (as produced by the
  ProviderPool) and return the selected provider id or nil if no candidates.
  """

  @type candidate :: %{
          required(:id) => String.t(),
          required(:config) => map(),
          optional(:availability) => :up | :limited | :down | :misconfigured
        }

  @type context :: %{
          optional(:chain) => String.t(),
          optional(:metrics) => module(),
          optional(:now_ms) => integer(),
          optional(atom()) => any()
        }

  @callback choose(candidates :: [candidate], method :: String.t() | nil, ctx :: context()) ::
              String.t() | nil
end
