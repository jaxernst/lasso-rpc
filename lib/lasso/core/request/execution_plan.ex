defmodule Lasso.RPC.ExecutionPlan do
  @moduledoc "Immutable routing and policy input for one candidate admission."

  alias Lasso.RPC.ExecutionFact

  defmodule Candidate do
    @moduledoc false
    @enforce_keys [:upstream_instance_id, :transport]
    defstruct @enforce_keys ++ [:provider_id]

    def new(attrs) do
      candidate = struct!(__MODULE__, attrs)

      %{
        candidate
        | upstream_instance_id:
            ExecutionFact.bounded!(candidate.upstream_instance_id, :upstream_instance_id),
          provider_id: ExecutionFact.optional_bounded!(candidate.provider_id, :provider_id),
          transport: ExecutionFact.transport!(candidate.transport)
      }
    end
  end

  defmodule Policy do
    @moduledoc false
    @strategies [:fastest, :load_balanced, :latency_weighted, :priority]
    @enforce_keys [:strategy]
    defstruct @enforce_keys ++ [provider_override: nil, failover_on_override: false]

    def new(attrs) do
      policy = struct!(__MODULE__, attrs)

      unless is_boolean(policy.failover_on_override),
        do: raise(ArgumentError, "failover_on_override must be boolean")

      %{
        policy
        | strategy: ExecutionFact.member!(policy.strategy, :strategy, @strategies),
          provider_override:
            ExecutionFact.optional_bounded!(policy.provider_override, :provider_override)
      }
    end
  end

  @workload_classes [:read, :transaction, :filter, :subscription, :unknown]
  @enforce_keys [:profile, :workload_key, :workload_class, :route_generation, :candidate, :policy]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(attrs) do
    plan = struct!(__MODULE__, attrs)

    unless match?(%Candidate{}, plan.candidate) and match?(%Policy{}, plan.policy),
      do: raise(ArgumentError, "candidate and policy must be typed plan fragments")

    candidate = Candidate.new(Map.to_list(Map.from_struct(plan.candidate)))
    policy = Policy.new(Map.to_list(Map.from_struct(plan.policy)))

    %{
      plan
      | profile: ExecutionFact.bounded!(plan.profile, :profile),
        workload_key: ExecutionFact.bounded!(plan.workload_key, :workload_key),
        workload_class:
          ExecutionFact.member!(plan.workload_class, :workload_class, @workload_classes),
        route_generation: ExecutionFact.non_negative!(plan.route_generation, :route_generation),
        candidate: candidate,
        policy: policy
    }
  end
end

defmodule Lasso.RPC.AdmissionLease do
  @moduledoc "Composite bounded lease assembled in fixed acquisition order."

  alias Lasso.RPC.ExecutionFact

  @order [:breaker, :node_bulkhead, :upstream_bulkhead, :workload]
  @enforce_keys [:token, :owner, :fragments]
  defstruct @enforce_keys
  @type fragment :: %{required(:kind) => atom(), required(:token) => binary()}
  @type t :: %__MODULE__{token: binary(), owner: pid(), fragments: [fragment()]}

  @spec new(binary(), pid()) :: t()
  def new(token, owner) when is_pid(owner) do
    %__MODULE__{token: ExecutionFact.bounded!(token, :token), owner: owner, fragments: []}
  end

  @spec add(t(), atom(), binary()) :: t()
  def add(%__MODULE__{} = lease, kind, token) when kind in @order do
    previous_index =
      case List.last(lease.fragments) do
        nil -> -1
        fragment -> Enum.find_index(@order, &(&1 == fragment.kind))
      end

    next_index = Enum.find_index(@order, &(&1 == kind))

    if next_index <= previous_index,
      do: raise(ArgumentError, "lease fragments must be acquired in fixed order")

    fragment = %{kind: kind, token: ExecutionFact.bounded!(token, :fragment_token)}
    %{lease | fragments: lease.fragments ++ [fragment]}
  end

  def add(%__MODULE__{}, kind, _token),
    do: raise(ArgumentError, "invalid lease fragment: #{inspect(kind)}")

  @spec rollback_order(t()) :: [fragment()]
  def rollback_order(%__MODULE__{fragments: fragments}), do: Enum.reverse(fragments)
end
