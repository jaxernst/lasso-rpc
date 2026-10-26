defmodule Lasso.RPC.ProviderKnowledge.TemplateClassification do
  @moduledoc "Bounded shadow counts of masked-template hypotheses beside serving classifications."

  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.RPC.AttemptTerminal.Response
  alias Lasso.RPC.ProviderKnowledge.Effects

  @event [:lasso, :provider_knowledge, :classifier_shadow]
  @table :lasso_provider_knowledge_classifier_shadow
  @max_keys 64

  @spec create_table!() :: :ok
  def create_table! do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    :ok
  end

  @spec counts() :: [map()]
  def counts do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {{status, category}, count} ->
      %{status: status, predicted_category: category, count: count}
    end)
    |> Enum.sort_by(&{&1.status, &1.predicted_category})
  rescue
    ArgumentError -> []
  end

  @spec observe(map(), map() | nil, String.t()) :: :ok
  def observe(outcome, prepared, profile) do
    if Effects.classifier_mode(profile) == :shadow do
      compare(outcome, prepared)
    end

    :ok
  end

  defp compare(
         %{fact: %Response{kind: :application_error, error_code: code}, result: result},
         %{fingerprint: fingerprint}
       ) do
    case result do
      {:error, %JError{category: category}} -> compare(code, fingerprint, category)
      {:error, %JError{category: category}, _elapsed} -> compare(code, fingerprint, category)
      _ -> :ok
    end
  end

  defp compare(_outcome, _prepared), do: :ok

  defp compare(code, fingerprint, category)
       when category in [:unclassified_server_error, :unknown_error] do
    case adapter().lookup(code, fingerprint) do
      {:ok, %{status: status, interpretation: %{"category" => predicted}} = entry}
      when status in [:proposed, :confirmed] and is_binary(predicted) ->
        count(status, predicted)

        :telemetry.execute(@event, %{count: 1}, %{
          error_code: code,
          fingerprint: fingerprint,
          predicted_category: predicted,
          interpretation_status: status,
          serving_category: category,
          interpreter: entry.interpreter
        })

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp compare(_code, _fingerprint, _category), do: :ok

  defp count(status, predicted) do
    key = {status, predicted}

    key =
      if :ets.member(@table, key) or :ets.info(@table, :size) < @max_keys,
        do: key,
        else: {:overflow, "other"}

    :ets.update_counter(@table, key, {2, 1}, {key, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp adapter do
    Application.get_env(:lasso, :provider_knowledge_template_catalog, __MODULE__.None)
  end
end

defmodule Lasso.RPC.ProviderKnowledge.TemplateClassification.None do
  @moduledoc false

  @spec lookup(integer(), binary()) :: :unknown
  def lookup(_code, _fingerprint), do: :unknown
end
