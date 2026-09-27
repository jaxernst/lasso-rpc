defmodule Lasso.RPC.RoutingEvidence.Reader do
  @moduledoc """
  Read contract for compact, published routing-evidence summaries.
  """

  alias Lasso.RPC.RoutingEvidence.Summary

  @type upstream_key :: {String.t(), :http | :ws}

  @callback batch_get_summaries(pos_integer(), atom(), [upstream_key()]) ::
              %{upstream_key() => Summary.t() | nil}
end
