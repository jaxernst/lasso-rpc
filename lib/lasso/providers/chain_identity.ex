defmodule Lasso.Providers.ChainIdentity do
  @moduledoc """
  Observed HTTP chain identity, scoped to a physical endpoint.

  Configuration generation fences probe writes; rejection survives unrelated
  configuration changes until a matching probe or physical endpoint teardown.

  Unknown identity preserves normal admission. An explicit malformed or mismatched
  `eth_chainId` response rejects HTTP admission until a later matching probe.
  Transport failures and JSON-RPC errors cannot establish or clear identity.
  HTTP observations never authorize or reject the independent WebSocket endpoint.
  """

  alias Lasso.Config.ConfigStore
  alias Lasso.Providers.Catalog

  @table :lasso_instance_state

  @type observation :: %{
          instance_id: String.t(),
          generation: non_neg_integer(),
          sequence: pos_integer()
        }

  @spec validate(term(), pos_integer()) :: :ok | {:error, String.t()}
  def validate("0x" <> digits, expected_chain_id)
      when is_integer(expected_chain_id) do
    if Regex.match?(~r/\A(?:0|[1-9a-fA-F][0-9a-fA-F]*)\z/, digits) do
      case String.to_integer(digits, 16) do
        ^expected_chain_id -> :ok
        actual -> {:error, "wrong chain_id: got #{actual}, expected #{expected_chain_id}"}
      end
    else
      {:error, "invalid chain_id response"}
    end
  end

  def validate(_, _), do: {:error, "invalid chain_id response"}

  @spec capture(String.t(), Catalog.snapshot()) :: observation()
  def capture(instance_id, %{generation: generation}) do
    %{
      instance_id: instance_id,
      generation: generation,
      sequence: System.unique_integer([:positive, :monotonic])
    }
  end

  @spec record(observation(), :verified | :rejected) :: :ok
  def record(%{instance_id: id, generation: generation, sequence: sequence}, status)
      when status in [:verified, :rejected] do
    if Catalog.active_generation() == generation and ConfigStore.route_generation() == generation do
      key = {:chain_identity, id, :http}
      row = {key, generation, sequence, status}

      unless :ets.insert_new(@table, row) do
        :ets.select_replace(@table, [
          {{key, :"$1", :"$2", :_},
           [
             {:orelse, {:<, :"$1", generation},
              {:andalso, {:==, :"$1", generation}, {:<, :"$2", sequence}}}
           ], [{:const, row}]}
        ])
      end
    end

    :ok
  end

  @spec check(String.t(), :http | :ws) ::
          :ok | {:error, :chain_identity_rejected}
  def check(instance_id, :http) do
    case :ets.lookup(@table, {:chain_identity, instance_id, :http}) do
      [{_, _, _, :rejected}] -> {:error, :chain_identity_rejected}
      _ -> :ok
    end
  end

  def check(_instance_id, :ws), do: :ok
end
