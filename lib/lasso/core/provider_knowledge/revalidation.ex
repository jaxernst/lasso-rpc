defmodule Lasso.RPC.ProviderKnowledge.Revalidation do
  @moduledoc "Body-free attribution of a system capability check to retained client knowledge."

  alias Lasso.Discovery.{ChainRegistry, TestParams}
  alias Lasso.JSONRPC.Quantity
  alias Lasso.RPC.ProviderKnowledge.Evidence
  alias Lasso.RPC.Response.Success
  alias Lasso.RPC.RoutingEvidence.Workload

  @max_quantity_response_bytes 4_096

  @enforce_keys [:subject, :epoch, :partition, :method, :resource]
  defstruct @enforce_keys ++ [minimum_age: nil, target_height: nil]

  @type t :: %__MODULE__{}

  @doc "Builds a bounded public fixture; never retains or replays a client's parameters."
  @spec fixture(pos_integer(), binary(), non_neg_integer() | nil) ::
          {:ok, list()} | {:error, atom()}
  def fixture(chain_id, "eth_blockNumber", nil) when is_integer(chain_id) and chain_id > 0,
    do: {:ok, []}

  def fixture(chain_id, method, block)
      when is_integer(chain_id) and chain_id > 0 and is_integer(block) and block >= 0 do
    contract = chain_id |> ChainRegistry.name_for() |> TestParams.busy_contract_for()

    case {contract, method} do
      {contract, "eth_getCode"} when is_binary(contract) ->
        {:ok, [contract, TestParams.int_to_hex(block)]}

      {contract, "eth_call"} when is_binary(contract) ->
        {:ok,
         [
           %{"to" => contract, "data" => "0x313ce567", "gas" => "0x186a0"},
           TestParams.int_to_hex(block)
         ]}

      _ ->
        {:error, :no_verifiable_fixture}
    end
  end

  def fixture(_chain_id, _method, _block), do: {:error, :no_verifiable_fixture}

  @doc "Only the historical learner may use this attribution; origin remains system."
  @spec partition(Evidence.t(), map()) :: atom() | nil
  def partition(evidence, %{
        request_origin: :system,
        observation_activity: :revalidation,
        capability_revalidation: %__MODULE__{} = token
      }) do
    if valid?(token) and token.subject == evidence.subject and
         token.epoch == evidence.epoch and token.method == evidence.method and
         token.resource == evidence.historical_resource and
         target_matches?(token, evidence),
       do: token.partition
  end

  def partition(_evidence, _opts), do: nil

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = token) do
    is_binary(token.subject) and byte_size(token.subject) in 1..128 and
      is_integer(token.epoch) and token.epoch >= 0 and
      token.partition in Workload.partitions() and
      token.partition in [:client_state] and
      token.method in ["eth_getCode", "eth_call"] and token.resource == :state and
      ((is_integer(token.target_height) and token.target_height >= 0) or
         (is_integer(token.minimum_age) and token.minimum_age >= 0))
  end

  def valid?(_), do: false

  defp target_matches?(%__MODULE__{target_height: height}, evidence) when is_integer(height),
    do: Map.get(evidence, :historical_height) == {height, height}

  defp target_matches?(%__MODULE__{minimum_age: age}, evidence),
    do: is_integer(age) and is_integer(evidence.historical_age) and evidence.historical_age >= age

  @doc "Empty or unexpected fixture results cannot retract a retained constraint."
  @spec verification(term(), binary()) :: :known_answer | :non_empty | nil
  def verification({:ok, %Success{} = response, _elapsed}, method),
    do: verification({:ok, response}, method)

  def verification({:ok, %Success{} = response}, "eth_call") do
    case Success.decode_result(response) do
      {:ok, result} when is_binary(result) ->
        if result == "0x" <> String.duplicate("0", 63) <> "6", do: :known_answer

      _ ->
        nil
    end
  end

  def verification({:ok, %Success{} = response}, "eth_getCode") do
    if Success.verifiable_nonempty?(response, "eth_getCode"), do: :non_empty
  end

  # Only the dedicated system recovery consumer uses this bounded decode.
  # An oversized or malformed probe is inconclusive, not proof of recovery.
  def verification({:ok, %Success{raw_bytes: bytes} = response}, "eth_blockNumber")
      when is_binary(bytes) and byte_size(bytes) <= @max_quantity_response_bytes do
    with {:ok, result} when is_binary(result) and byte_size(result) <= 66 <-
           Success.decode_result(response),
         {:ok, _height} <- Quantity.decode(result),
         do: :known_answer,
         else: (_ -> nil)
  end

  def verification(_, _), do: nil
end
