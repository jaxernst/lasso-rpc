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

  @doc """
  Classifies error and returns complete classification map.

  ## Parameters

  - `code` - Error code (integer)
  - `message` - Error message (string or nil)
  - `opts` - Options keyword list
    - `:provider_id` - Provider identifier (optional)
    - `:profile` - Profile slug for config lookup (optional)
    - `:chain` - Chain name for config lookup (optional)

  ## Returns

  Map with `:category`, `:retriable?`, `:breaker_penalty?`
  """
  @spec classify(integer(), String.t() | nil, keyword()) :: %{
          category: atom(),
          retriable?: boolean(),
          breaker_penalty?: boolean()
        }
  def classify(code, message, opts \\ []) do
    provider_id = Keyword.get(opts, :provider_id)
    profile = Keyword.get(opts, :profile)
    chain = Keyword.get(opts, :chain)

    category = classify_category(code, message, provider_id, profile, chain)

    retriable? = ErrorClassification.retriable_for_category?(category)
    breaker_penalty? = ErrorClassification.breaker_penalty?(category)

    %{
      category: category,
      retriable?: retriable?,
      breaker_penalty?: breaker_penalty?
    }
  end

  defp classify_category(code, message, provider_id, profile, chain)
       when is_binary(provider_id) do
    caps = lookup_capabilities(profile, chain, provider_id)

    case Capabilities.classify_error(code, message, caps) do
      {:ok, category} when is_atom(category) ->
        category

      :default ->
        ErrorClassification.categorize(code, message)
    end
  rescue
    exception ->
      Logger.error(
        "Capabilities (provider: #{provider_id}) crashed in classify_error: #{Exception.message(exception)}"
      )

      ErrorClassification.categorize(code, message)
  end

  defp classify_category(code, message, _provider_id, _profile, _chain) do
    ErrorClassification.categorize(code, message)
  end

  defp lookup_capabilities(profile, chain, provider_id)
       when is_binary(profile) and is_binary(chain) do
    case Lasso.Config.ConfigStore.get_provider(profile, chain, provider_id) do
      {:ok, provider_config} -> provider_config.capabilities
      {:error, :not_found} -> nil
    end
  end

  defp lookup_capabilities(_profile, _chain, _provider_id), do: nil
end
