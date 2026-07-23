defmodule Lasso.Core.Support.ErrorClassifier do
  @moduledoc """
  Unified error classification with provider-specific overrides.

  Classification flow:
  1. Attempts provider-specific classification via declarative error_rules
  2. Falls back to centralized classification rules
  3. Derives all properties (retriable?, breaker_penalty?) from the final category
  """

  alias Lasso.Core.Support.ErrorClassification
  alias Lasso.RPC.Providers.Capabilities

  require Logger

  @spec classify(integer(), String.t() | nil, keyword()) :: %{
          category: atom(),
          retriable?: boolean(),
          breaker_penalty?: boolean()
        }
  def classify(code, message, opts \\ []) do
    provider_id = Keyword.get(opts, :provider_id)
    profile = Keyword.get(opts, :profile)
    chain = Keyword.get(opts, :chain_id) || Keyword.get(opts, :chain)
    data = Keyword.get(opts, :data)

    {category, classification_path} =
      classify_with_path(code, message, data, provider_id, profile, chain)

    retriable? = ErrorClassification.retriable_for_category?(category)
    breaker_penalty? = ErrorClassification.breaker_penalty?(category)

    emit_classification_telemetry(
      code,
      message,
      data,
      provider_id,
      category,
      classification_path
    )

    if category == :unclassified_server_error do
      Logger.warning("Unclassified -32000 error",
        code: code,
        message: message,
        provider_id: provider_id,
        classification_path: classification_path
      )
    end

    %{
      category: category,
      retriable?: retriable?,
      breaker_penalty?: breaker_penalty?
    }
  end

  defp classify_with_path(code, message, data, provider_id, profile, chain)
       when is_binary(provider_id) do
    caps = lookup_capabilities(profile, chain, provider_id)

    case Capabilities.classify_error(code, message, caps) do
      {:ok, category} when is_atom(category) ->
        {category, :provider_rule}

      :default ->
        ErrorClassification.categorize_with_path(code, message, data)
    end
  rescue
    exception ->
      Logger.error(
        "Capabilities (provider: #{provider_id}) crashed in classify_error: #{Exception.message(exception)}"
      )

      ErrorClassification.categorize_with_path(code, message, data)
  end

  defp classify_with_path(code, message, data, _provider_id, _profile, _chain) do
    ErrorClassification.categorize_with_path(code, message, data)
  end

  defp emit_classification_telemetry(code, message, data, provider_id, category, path) do
    :telemetry.execute(
      [:lasso, :error_classification, :classified],
      %{count: 1},
      %{
        code: code,
        message: message,
        data_sample: truncate_data(data),
        provider_id: provider_id,
        category: category,
        classification_path: path
      }
    )
  end

  defp truncate_data(nil), do: nil
  defp truncate_data(data) when is_binary(data), do: String.slice(data, 0, 200)
  defp truncate_data(%{"data" => inner}) when is_binary(inner), do: String.slice(inner, 0, 200)
  defp truncate_data(_), do: nil

  defp lookup_capabilities(profile, chain, provider_id)
       when is_binary(profile) and is_integer(chain) do
    case Lasso.Config.ConfigStore.get_provider(profile, chain, provider_id) do
      {:ok, provider_config} -> provider_config.capabilities
      {:error, :not_found} -> nil
    end
  end

  defp lookup_capabilities(_profile, _chain, _provider_id), do: nil
end
