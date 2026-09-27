defmodule Lasso.RPC.RoutingEvidence.Workload do
  @moduledoc """
  Finite request families crossed with client or system origin.

  Unknown methods share one partition. System observations can seed ordering only
  within the same family and never qualify client routing.
  """

  alias Lasso.RPC.MethodRegistry

  @families [:basic, :state, :logs, :trace, :transaction, :subscription]
  @client_partitions [
    :client,
    :client_basic,
    :client_state,
    :client_logs,
    :client_trace,
    :client_transaction,
    :client_subscription
  ]
  @system_partitions [
    :system,
    :system_basic,
    :system_state,
    :system_logs,
    :system_trace,
    :system_transaction,
    :system_subscription
  ]
  @partitions @client_partitions ++ @system_partitions
  @encodings Map.new(@partitions, &{Atom.to_string(&1), &1})
  @family_partitions Map.new(
                       Enum.zip(
                         @families,
                         Enum.zip(tl(@client_partitions), tl(@system_partitions))
                       )
                     )

  @system_by_client Map.new(Enum.zip(@client_partitions, @system_partitions))

  @type t ::
          :client
          | :system
          | :client_basic
          | :system_basic
          | :client_state
          | :system_state
          | :client_logs
          | :system_logs
          | :client_trace
          | :system_trace
          | :client_transaction
          | :system_transaction
          | :client_subscription
          | :system_subscription
  @type family :: :basic | :state | :logs | :trace | :transaction | :subscription | :unknown

  @spec client_partitions() :: [t()]
  def client_partitions, do: @client_partitions
  @spec partitions() :: [t()]
  def partitions, do: @partitions
  @spec client?(term()) :: boolean()
  def client?(workload), do: workload in @client_partitions
  @spec system?(term()) :: boolean()
  def system?(workload), do: workload in @system_partitions

  @spec for_origin(:client | :system) :: t()
  def for_origin(:system), do: :system
  def for_origin(_origin), do: :client

  @spec for_request(:client | :system, binary()) :: t()
  def for_request(origin, method) do
    case Map.get(@family_partitions, family(method)) do
      nil -> for_origin(origin)
      {client, system} -> if origin == :system, do: system, else: client
    end
  end

  @spec family(binary()) :: family()
  def family(method) when method in ["eth_getBalance", "eth_getCode"], do: :state

  def family(method) do
    case MethodRegistry.method_category(method) do
      category when category in [:core, :network, :node_admin, :eip1559, :eip4844] -> :basic
      category when category in [:state, :extended_reads] -> :state
      :filters -> :logs
      category when category in [:debug, :trace] -> :trace
      :mempool -> :transaction
      :subscriptions -> :subscription
      _unknown -> :unknown
    end
  end

  @spec system_partition(t()) :: t()
  def system_partition(workload) do
    Map.get(@system_by_client, workload, workload)
  end

  @spec normalize(term()) :: t()
  def normalize(workload) when workload in @partitions, do: workload
  def normalize(workload) when is_binary(workload), do: Map.get(@encodings, workload, :client)
  def normalize(_workload), do: :client

  @spec encode(t()) :: binary()
  def encode(workload) when workload in @partitions, do: Atom.to_string(workload)
  @spec decode(binary()) :: t() | :unknown
  def decode("default"), do: :client
  def decode(workload), do: Map.get(@encodings, workload, :unknown)
end
