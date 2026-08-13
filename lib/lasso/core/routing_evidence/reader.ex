defmodule Lasso.RPC.RoutingEvidence.Reader do
  @moduledoc """
  Read contract for compact, published routing-evidence summaries.
  """

  alias Lasso.RPC.RoutingEvidence.Summary

  @type upstream_key :: {String.t(), :http | :ws}

  @callback batch_get_summaries(pos_integer(), atom(), [upstream_key()]) ::
              %{upstream_key() => Summary.t() | nil}
end

defmodule Lasso.RPC.RoutingEvidence.UnavailableReader do
  @moduledoc false
  @behaviour Lasso.RPC.RoutingEvidence.Reader

  @impl true
  def batch_get_summaries(_chain_id, _workload_key, upstream_keys) do
    Map.new(upstream_keys, &{&1, nil})
  end
end
