defmodule Lasso.Core.Support.ErrorClassifier do
  @moduledoc """
  Unified error classification with provider-specific overrides.

  Classification flow:
  1. Attempts provider-specific classification via declarative error_rules
  2. Falls back to centralized classification rules
  3. Derives all properties (retriable?, breaker_penalty?) from the final category
  """

  alias Lasso.Core.Support.ErrorClassification
  alias Lasso.Providers.Catalog
  alias Lasso.RPC.Providers.Capabilities

  require Logger

  @max_classification_message_graphemes 4_096

  @spec classify(integer(), String.t() | nil, keyword()) :: %{
          category: atom(),
          control_category: atom(),
          retriable?: boolean(),
          breaker_penalty?: boolean()
        }
  def classify(code, message, opts \\ []) do
    message = bounded_message(message)
    message_fingerprint = message_fingerprint(message)
    provider_id = Keyword.get(opts, :provider_id)
    profile = Keyword.get(opts, :profile)
    chain = Keyword.get(opts, :chain_id) || Keyword.get(opts, :chain)
    capabilities = Keyword.get(opts, :provider_capabilities)
    data = Keyword.get(opts, :data)

    {baseline_category, baseline_path} =
      ErrorClassification.categorize_with_path(code, message, data)

    {category, classification_path} =
      if definitive_baseline_evidence?(baseline_category, baseline_path) do
        {baseline_category, baseline_path}
      else
        classify_with_path(code, message, data, provider_id, profile, chain, capabilities)
      end

    shared_control? =
      classification_path == :provider_rule and
        shared_control_scope?(opts, profile, chain, provider_id)

    control_category = if shared_control?, do: baseline_category, else: category

    retriable? = ErrorClassification.retriable_for_category?(category)
    breaker_penalty? = ErrorClassification.breaker_penalty?(category)

    emit_classification_telemetry(
      code,
      message_fingerprint,
      data_kind(data),
      provider_id,
      category,
      classification_path,
      control_category,
      shared_control?
    )

    if category == :unclassified_server_error do
      Logger.warning("Unclassified -32000 error",
        code: code,
        provider_id: provider_id,
        classification_path: classification_path,
        message_fingerprint: message_fingerprint,
        data_kind: data_kind(data)
      )
    end

    %{
      category: category,
      control_category: control_category,
      retriable?: retriable?,
      breaker_penalty?: breaker_penalty?
    }
  end

  defp classify_with_path(code, message, data, provider_id, _profile, _chain, capabilities)
       when is_binary(provider_id) and is_map(capabilities) do
    classify_from_capabilities(code, message, data, provider_id, capabilities)
  end

  defp classify_with_path(code, message, data, provider_id, profile, chain, _capabilities)
       when is_binary(provider_id) do
    caps = lookup_capabilities(profile, chain, provider_id)

    classify_from_capabilities(code, message, data, provider_id, caps)
  end

  defp classify_with_path(code, message, data, _provider_id, _profile, _chain, _capabilities) do
    ErrorClassification.categorize_with_path(code, message, data)
  end

  defp definitive_baseline_evidence?(:execution_revert, _path), do: true

  defp definitive_baseline_evidence?(_category, :definitive_code), do: true

  defp definitive_baseline_evidence?(_category, _path), do: false

  defp classify_from_capabilities(code, message, data, provider_id, capabilities) do
    case Capabilities.classify_error(code, message, capabilities) do
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

  defp emit_classification_telemetry(
         code,
         message_fingerprint,
         data_kind,
         provider_id,
         category,
         path,
         control_category,
         shared_control?
       ) do
    :telemetry.execute(
      [:lasso, :error_classification, :classified],
      %{count: 1},
      %{
        code: code,
        message_fingerprint: message_fingerprint,
        data_kind: data_kind,
        provider_id: provider_id,
        category: category,
        classification_path: path,
        control_category: control_category,
        shared_control?: shared_control?
      }
    )
  end

  defp shared_control_scope?(opts, profile, chain, provider_id) do
    case Keyword.fetch(opts, :shared_instance?) do
      {:ok, shared?} when is_boolean(shared?) ->
        shared?

      :error ->
        shared_instance?(profile, chain, provider_id)
    end
  end

  defp shared_instance?(profile, chain, provider_id)
       when is_binary(profile) and is_integer(chain) and is_binary(provider_id) do
    case Catalog.lookup_instance_id(profile, chain, provider_id) do
      instance_id when is_binary(instance_id) ->
        case Catalog.get_instance_refs(instance_id) do
          [_single_profile] -> false
          [_first_profile, _second_profile | _rest] -> true
          _unknown -> false
        end

      nil ->
        false
    end
  end

  defp shared_instance?(_profile, _chain, _provider_id), do: false

  defp message_fingerprint(nil), do: nil

  defp message_fingerprint(message) do
    normalized =
      message
      |> String.downcase()
      |> String.replace(~r/0x[0-9a-f]+/i, "<hex>")
      |> String.replace(~r/\d+/, "<number>")
      |> String.trim()

    :sha256
    |> :crypto.hash(normalized)
    |> Base.encode16(case: :lower)
  end

  defp data_kind(nil), do: :none
  defp data_kind(data) when is_binary(data), do: :binary
  defp data_kind(data) when is_map(data), do: :object

  defp bounded_message(message) when is_binary(message),
    do: String.slice(message, 0, @max_classification_message_graphemes)

  defp bounded_message(message), do: message

  defp lookup_capabilities(profile, chain, provider_id)
       when is_binary(profile) and is_integer(chain) do
    case Lasso.Config.ConfigStore.get_provider(profile, chain, provider_id) do
      {:ok, provider_config} -> provider_config.capabilities
      {:error, :not_found} -> nil
    end
  end

  defp lookup_capabilities(_profile, _chain, _provider_id), do: nil
end
