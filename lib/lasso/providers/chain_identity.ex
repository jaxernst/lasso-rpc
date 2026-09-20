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
