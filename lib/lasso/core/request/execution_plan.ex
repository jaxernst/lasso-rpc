defmodule Lasso.RPC.ExecutionPlan do
  @moduledoc "Immutable routing and policy input for one candidate admission."

  alias Lasso.RPC.ExecutionFact

  @candidate_keys [:upstream_instance_id, :provider_id, :transport]
  @policy_keys [:strategy, :provider_override, :failover_on_override]

  @enforce_keys [:profile, :workload_key, :route_generation, :candidate, :policy]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(attrs) do
    plan = struct!(__MODULE__, attrs)

    unless bounded_fragment?(plan.candidate, @candidate_keys) and
             bounded_fragment?(plan.policy, @policy_keys),
           do: raise(ArgumentError, "candidate and policy must be maps")

    if external_size(plan.candidate) > 1_024 or external_size(plan.policy) > 1_024,
      do: raise(ArgumentError, "execution plan fragments exceed their bounded size")

    %{
      plan
      | profile: ExecutionFact.bounded!(plan.profile, :profile),
        workload_key: ExecutionFact.bounded!(plan.workload_key, :workload_key),
        route_generation: ExecutionFact.non_negative!(plan.route_generation, :route_generation)
    }
  end

  defp external_size(value), do: value |> :erlang.term_to_binary() |> byte_size()

  defp bounded_fragment?(fragment, allowed_keys) when is_map(fragment) do
    Enum.all?(fragment, fn {key, value} ->
      key in allowed_keys and bounded_scalar?(value)
    end)
  end

  defp bounded_fragment?(_fragment, _allowed_keys), do: false

  defp bounded_scalar?(value) when is_binary(value),
    do: byte_size(value) <= 128 and String.valid?(value)

  defp bounded_scalar?(value) when is_atom(value) or is_boolean(value) or is_nil(value), do: true
  defp bounded_scalar?(_value), do: false
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
    expected = Enum.at(@order, length(lease.fragments))

    if kind != expected,
      do: raise(ArgumentError, "lease fragments must be acquired in fixed order")

    fragment = %{kind: kind, token: ExecutionFact.bounded!(token, :fragment_token)}
    %{lease | fragments: lease.fragments ++ [fragment]}
  end

  def add(%__MODULE__{}, kind, _token),
    do: raise(ArgumentError, "invalid lease fragment: #{inspect(kind)}")

  @spec rollback_order(t()) :: [fragment()]
  def rollback_order(%__MODULE__{fragments: fragments}), do: Enum.reverse(fragments)
end
