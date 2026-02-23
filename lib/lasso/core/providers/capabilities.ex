defmodule Lasso.RPC.Providers.Capabilities do
  @moduledoc """
  Declarative provider capabilities engine.

  Provider capabilities are declared as plain maps (from YAML config)
  and evaluated at runtime for method filtering, parameter validation,
  and error classification.

  When `capabilities` is nil on a provider, defaults to permissive behavior:
  only `:local_only` methods are blocked, no custom error rules, no limits.
  Unknown/non-standard methods are allowed through (fail-open).
  """

  alias Lasso.RPC.MethodRegistry
  alias Lasso.RPC.Providers.AdapterHelpers

  @default_unsupported_categories [:local_only]

  @valid_error_categories [
    :rate_limit,
    :capability_violation,
    :server_error,
    :requires_archival,
    :auth_error,
    :network_error,
    :client_error,
    :invalid_params,
    :method_not_found,
    :parse_error,
    :internal_error,
    :unknown_error,
    :method_error,
    :chain_error,
    :user_error
  ]

  @doc """
  Returns permissive default capabilities (everything supported except local_only).
  """
  @spec default_capabilities() :: map()
  def default_capabilities do
    %{
      unsupported_categories: @default_unsupported_categories,
      unsupported_methods: [],
      limits: %{},
      error_rules: []
    }
  end

  @doc """
  Checks if a provider supports a given method based on its capabilities.

  Returns `:ok` if supported, `{:error, :method_unsupported}` if not.
  """
  @spec supports_method?(String.t(), map() | nil) :: :ok | {:error, :method_unsupported}
  def supports_method?(method, nil), do: supports_method?(method, default_capabilities())

  def supports_method?(method, capabilities) when is_map(capabilities) do
    unsupported_categories =
      Map.get(capabilities, :unsupported_categories, @default_unsupported_categories)

    unsupported_methods = Map.get(capabilities, :unsupported_methods, [])

    cond do
      method in unsupported_methods ->
        {:error, :method_unsupported}

      MethodRegistry.method_category(method) in unsupported_categories ->
        {:error, :method_unsupported}

      true ->
        :ok
    end
  end

  @doc """
  Validates request parameters against provider capability limits.

  Checks:
  - `max_block_range` for eth_getLogs
  - `max_block_age` + `block_age_methods` for state methods
  """
  @spec validate_params(String.t(), list(), map() | nil, map()) :: :ok | {:error, term()}
  def validate_params(_method, _params, nil, _ctx), do: :ok

  def validate_params(method, params, capabilities, ctx) when is_map(capabilities) do
    limits = Map.get(capabilities, :limits, %{})
    validate_limits(method, params, limits, ctx)
  end

  @doc """
  Classifies a provider error using declarative error rules.

  Evaluates rules top-to-bottom; first match wins.
  Returns `{:ok, category}` or `:default` (defer to centralized classification).
  """
  @spec classify_error(integer(), String.t() | nil, map() | nil) :: {:ok, atom()} | :default
  def classify_error(_code, _message, nil), do: :default

  def classify_error(code, message, capabilities) when is_map(capabilities) do
    rules = Map.get(capabilities, :error_rules, [])
    evaluate_error_rules(code, message, rules, 0)
  end

  @doc """
  Validates capabilities schema at boot time. Raises on invalid config.
  """
  @spec validate!(String.t(), map() | nil) :: :ok
  def validate!(_provider_id, nil), do: :ok

  def validate!(provider_id, capabilities) when is_map(capabilities) do
    validate_unsupported_categories!(provider_id, capabilities)
    validate_error_rules!(provider_id, capabilities)
    validate_limits!(provider_id, capabilities)
    :ok
  end

  # --- Private ---

  defp validate_limits(method, params, limits, ctx) do
    with :ok <- maybe_validate_block_range(method, params, limits, ctx) do
      maybe_validate_block_age(method, params, limits, ctx)
    end
  end

  defp maybe_validate_block_range("eth_getLogs", params, %{max_block_range: limit}, ctx)
       when is_integer(limit) do
    AdapterHelpers.validate_block_range(params, ctx, limit)
  end

  defp maybe_validate_block_range(_method, _params, _limits, _ctx), do: :ok

  defp maybe_validate_block_age(method, params, limits, ctx) do
    max_age = Map.get(limits, :max_block_age)
    age_methods = Map.get(limits, :block_age_methods, [])

    if max_age && method in age_methods do
      AdapterHelpers.validate_block_age(params, ctx, max_age)
    else
      :ok
    end
  end

  defp evaluate_error_rules(_code, _message, [], _index), do: :default

  defp evaluate_error_rules(code, message, [rule | rest], index) do
    if rule_matches?(code, message, rule) do
      :telemetry.execute(
        [:lasso, :capabilities, :error_rule_match],
        %{count: 1},
        %{rule_index: index, category: rule.category}
      )

      {:ok, rule.category}
    else
      evaluate_error_rules(code, message, rest, index + 1)
    end
  end

  defp rule_matches?(code, message, rule) do
    code_match = rule_code_matches?(code, rule)
    message_match = rule_message_matches?(message, rule)

    has_code = Map.has_key?(rule, :code)
    has_message = Map.has_key?(rule, :message_contains)

    cond do
      has_code and has_message -> code_match and message_match
      has_code -> code_match
      has_message -> message_match
      true -> false
    end
  end

  defp rule_code_matches?(code, %{code: rule_code}), do: code == rule_code
  defp rule_code_matches?(_code, _rule), do: false

  defp rule_message_matches?(nil, _rule), do: false

  defp rule_message_matches?(message, %{message_contains: patterns}) when is_list(patterns) do
    lower = String.downcase(message)
    Enum.any?(patterns, &String.contains?(lower, String.downcase(&1)))
  end

  defp rule_message_matches?(message, %{message_contains: pattern}) when is_binary(pattern) do
    String.contains?(String.downcase(message), String.downcase(pattern))
  end

  defp rule_message_matches?(_message, _rule), do: false

  # --- Boot-time schema validation ---

  defp validate_unsupported_categories!(provider_id, capabilities) do
    categories = Map.get(capabilities, :unsupported_categories, [])
    valid_categories = Map.keys(MethodRegistry.categories())

    Enum.each(categories, fn cat ->
      if cat not in valid_categories do
        raise """
        Provider "#{provider_id}": unsupported_categories contains "#{cat}" \
        which is not a valid method category.
        Valid categories: #{inspect(valid_categories)}
        """
      end
    end)
  end

  defp validate_error_rules!(provider_id, capabilities) do
    rules = Map.get(capabilities, :error_rules, [])

    Enum.with_index(rules, fn rule, idx ->
      unless Map.has_key?(rule, :code) or Map.has_key?(rule, :message_contains) do
        raise """
        Provider "#{provider_id}": error_rules[#{idx}] must have at least one of \
        :code or :message_contains.
        """
      end

      unless Map.has_key?(rule, :category) do
        raise """
        Provider "#{provider_id}": error_rules[#{idx}] must have exactly one :category.
        """
      end

      if rule.category not in @valid_error_categories do
        raise """
        Provider "#{provider_id}": error_rules[#{idx}].category "#{rule.category}" \
        is not a valid category.
        Valid categories: #{inspect(@valid_error_categories)}
        """
      end

      validate_message_contains_type!(provider_id, idx, rule)
    end)
  end

  defp validate_message_contains_type!(provider_id, idx, rule) do
    case Map.get(rule, :message_contains) do
      nil ->
        :ok

      val when is_binary(val) ->
        :ok

      val when is_list(val) ->
        unless Enum.all?(val, &is_binary/1) do
          raise """
          Provider "#{provider_id}": error_rules[#{idx}].message_contains list must \
          contain only strings, got: #{inspect(val)}
          """
        end

      val ->
        raise """
        Provider "#{provider_id}": error_rules[#{idx}].message_contains must be a \
        string or list of strings, got: #{inspect(val)}
        """
    end
  end

  defp validate_limits!(provider_id, capabilities) do
    limits = Map.get(capabilities, :limits, %{})

    for {key, value} <- limits, key in [:max_block_range, :max_block_age] do
      if value != nil and (not is_integer(value) or value < 0) do
        raise """
        Provider "#{provider_id}": limits.#{key} must be a non-negative integer or null, \
        got: #{inspect(value)}
        """
      end
    end

    case Map.get(limits, :block_age_methods) do
      nil ->
        :ok

      methods when is_list(methods) ->
        unless Enum.all?(methods, &is_binary/1) do
          raise """
          Provider "#{provider_id}": limits.block_age_methods must be a list of strings, \
          got: #{inspect(methods)}
          """
        end

      other ->
        raise """
        Provider "#{provider_id}": limits.block_age_methods must be a list of strings, \
        got: #{inspect(other)}
        """
    end
  end
end
