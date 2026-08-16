defmodule Lasso.RPC.RoutingEvidence.Workload do
  @moduledoc """
  Fixed routing-evidence partitions for client and system request traffic.

  The finite set keeps route-state cardinality bounded. System evidence may seed cold-start
  ordering, but only client evidence can qualify adaptive client routing.
  """

  @type t :: :client | :system

  @partitions [:client, :system]

  @spec for_origin(:client | :system) :: t()
  def for_origin(:client), do: :client
  def for_origin(:system), do: :system

  @spec normalize(term()) :: t()
  def normalize(:system), do: :system
  def normalize("system"), do: :system
  def normalize(_workload), do: :client

  @spec encode(t()) :: binary()
  def encode(workload) when workload in @partitions, do: Atom.to_string(workload)

  @spec decode(binary()) :: t() | :unknown
  def decode("client"), do: :client
  def decode("default"), do: :client
  def decode("system"), do: :system
  def decode(_workload), do: :unknown
end
