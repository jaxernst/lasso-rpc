defmodule Lasso.RPC.HistoricalCoverage do
  @moduledoc """
  Separates operator permission from historical observations and prediction.

  A sampled result applies to its checked resource and block only. Other
  methods, selectors and depths remain unknown and eligible for bounded work.
  """

  @type resource :: :blocks | :balance | :state | :logs | :receipts | :proofs | :traces | nil
  @type prediction ::
          :unknown
          | :observed_success
          | :observed_unavailable
          | :predicted_unavailable
          | :operator_restricted
  @probe_ttl_seconds 86_400

  alias Lasso.RPC.ProviderKnowledge
  alias Lasso.RPC.ProviderKnowledge.Learners.HistoricalDepth

  @spec predict(boolean() | nil, map() | nil, resource(), non_neg_integer() | nil) :: prediction()
  def predict(permission, capabilities, resource, height \\ nil)
  def predict(false, _capabilities, _resource, _height), do: :operator_restricted

  def predict(_permission, capabilities, resource, height)
      when is_map(capabilities) and is_integer(height) do
    if fresh_probe?(capabilities),
      do: observed_prediction(capabilities, resource, height),
      else: :unknown
  end

  def predict(_permission, _capabilities, _resource, _height), do: :unknown

  @spec predict(boolean() | nil, map() | nil, resource(), non_neg_integer() | nil, map()) ::
          prediction()
  def predict(false, _capabilities, _resource, _height, _scope), do: :operator_restricted

  def predict(permission, capabilities, resource, height, scope) when is_map(scope) do
    case ProviderKnowledge.historical_depth(scope, resource) do
      {:ok, hint} ->
        interval =
          Map.get(scope, :historical_height) || if(is_integer(height), do: {height, height})

        if HistoricalDepth.unavailable?(
             hint,
             Map.get(scope, :historical_age),
             interval
           ),
           do: :predicted_unavailable,
           else: predict(permission, capabilities, resource, height)

      _ ->
        predict(permission, capabilities, resource, height)
    end
  end

  defp observed_prediction(capabilities, resource, height) do
    cond do
      resource == :balance and witness(capabilities, :unavailable_state_block) == height ->
        :observed_unavailable

      resource == :balance and witness(capabilities, :observed_state_block) == height ->
        :observed_success

      resource == :logs and witness(capabilities, :observed_log_block) == height ->
        :observed_success

      true ->
        :unknown
    end
  end

  @spec eligible?(boolean() | nil, map() | nil, resource(), non_neg_integer() | nil) :: boolean()
  def eligible?(permission, _capabilities, _resource, _height \\ nil),
    do: permission != false

  defp witness(capabilities, key) do
    Map.get(capabilities, key, Map.get(capabilities, Atom.to_string(key)))
  end

  defp fresh_probe?(capabilities) do
    case witness(capabilities, :probe_observed_at) do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, time, _offset} ->
            age = System.system_time(:second) - DateTime.to_unix(time)
            age >= 0 and age < @probe_ttl_seconds

          _ ->
            false
        end

      _ ->
        false
    end
  end
end
