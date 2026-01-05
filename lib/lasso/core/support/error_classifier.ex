defmodule Lasso.Core.Support.ErrorClassifier do
  @moduledoc """
  Unified error classification with provider-specific overrides.

  This module provides a single entry point for error classification that:
  1. Attempts provider-specific classification first (via adapter callbacks)
  2. Falls back to centralized classification rules
  3. Derives all properties (retriable?, breaker_penalty?) from the final category

  ## Design Philosophy

  Classification happens once, then all other properties are derived from the
  final category. This ensures that provider adapter overrides propagate through
  to retriability and circuit breaker behavior consistently.

  ## Example

      # DRPC overrides code 30 as :rate_limit
      iex> classify(30, "timeout on free tier", provider_id: "drpc_ethereum")
      %{
        category: :rate_limit,      # From DRPC adapter
        retriable?: true,            # Derived from :rate_limit category
        breaker_penalty?: true       # Derived from :rate_limit category
      }

      # Generic provider uses central classification
      iex> classify(-32_000, "server error", provider_id: "generic_ethereum")
      %{
        category: :server_error,     # From central classification
        retriable?: true,            # Derived from :server_error category
        breaker_penalty?: true       # Derived from :server_error category
      }

  ## Composition

  When a provider adapter returns a category, that category determines ALL
  downstream behavior:
  - Circuit breaker behavior (breaker_penalty?)
  - Failover behavior (retriable?)
  - Observability (category name in logs/metrics)

  This prevents inconsistencies where an adapter overrides the category but
  retriability is determined from the original error code.
  """

  alias Lasso.Core.Support.ErrorClassification
  alias Lasso.RPC.Providers.AdapterRegistry

  require Logger

  @doc """
  Classifies error and returns complete classification map.

  Classification flow:
  1. Determine category (adapter override takes priority over central classification)
  2. Derive retriable? from final category
  3. Derive breaker_penalty? from final category

  This ensures adapter overrides affect ALL derived properties consistently.

  ## Parameters

  - `code` - Error code (integer, can be JSON-RPC, HTTP, or provider-specific)
  - `message` - Error message (string or nil)
  - `opts` - Options keyword list
    - `:provider_id` - Provider identifier for adapter lookup (optional)

  ## Returns

  Map with classification results:
  - `:category` - Error category atom (e.g., :rate_limit, :server_error)
  - `:retriable?` - Whether to try next provider on failure
  - `:breaker_penalty?` - Whether to count against circuit breaker threshold
  """
  @spec classify(integer(), String.t() | nil, keyword()) :: %{
          category: atom(),
          retriable?: boolean(),
          breaker_penalty?: boolean()
        }
  def classify(code, message, opts \\ []) do
    provider_id = Keyword.get(opts, :provider_id)

    # Step 1: Classify once (with adapter override taking priority)
    category = classify_category(code, message, provider_id)

    # Step 2: Derive all properties from final category
    retriable? = ErrorClassification.retriable_for_category?(category)
    breaker_penalty? = ErrorClassification.breaker_penalty?(category)

    %{
      category: category,
      retriable?: retriable?,
      breaker_penalty?: breaker_penalty?
    }
  end

  # ===========================================================================
  # Private: Category Classification with Adapter Priority
  # ===========================================================================

  # Determines category with adapter override taking priority
  defp classify_category(code, message, provider_id) when is_binary(provider_id) do
    adapter = AdapterRegistry.adapter_for(provider_id)

    # Check if adapter implements classify_error/2 using __info__(:functions)
    # This is more reliable than function_exported?/3 in async test environments
    # where module loading timing can cause false negatives
    if {:classify_error, 2} in adapter.__info__(:functions) do
      case adapter.classify_error(code, message) do
        {:ok, category} when is_atom(category) ->
          # Adapter provided classification - use it
          category

        :default ->
          # Adapter defers to central classification
          ErrorClassification.categorize(code, message)

        other ->
          # Invalid return value - log warning and fall back
          Logger.warning(
            "Adapter #{inspect(adapter)} returned invalid classify_error result: #{inspect(other)}"
          )

          ErrorClassification.categorize(code, message)
      end
    else
      # Adapter doesn't implement callback - use central classification
      ErrorClassification.categorize(code, message)
    end
  rescue
    exception ->
      # Adapter crashed - fail-safe to central classification
      Logger.error(
        "Adapter (provider: #{provider_id}) crashed in classify_error: #{Exception.message(exception)}"
      )

      ErrorClassification.categorize(code, message)
  end

  defp classify_category(code, message, _provider_id) do
    # No provider_id - use central classification
    ErrorClassification.categorize(code, message)
  end
end
