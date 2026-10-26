defmodule Lasso.RPC.Providers.Capabilities do
  @moduledoc """
  Declarative provider capabilities engine.

  Provider capabilities are declared as plain maps (from YAML config)
  and evaluated at runtime for method filtering, parameter validation,
  and error classification. Capability list fields must contain lists; use an
  empty list for no declarations.

  When `capabilities` is nil on a provider, defaults to permissive behavior:
  only `:local_only` methods are blocked, no custom error rules, no limits.
  Unknown/non-standard methods are allowed through (fail-open).
  """

  alias Lasso.RPC.MethodRegistry
  alias Lasso.RPC.Providers.AdapterHelpers

  @default_unsupported_categories [:local_only]
  @max_error_rules 32
  @max_message_patterns_per_rule 8
  @max_message_pattern_bytes 256

  @valid_error_categories [
    :rate_limit,
    :capability_violation,
    :block_not_available,
    :server_error,
    :requires_archival,
    :auth_error,
    :timeout,
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
  def supports_method?(method, capabilities) when is_binary(method) do
    supports_method?(method, MethodRegistry.method_category(method), capabilities)
  end

  @doc false
  @spec supports_method?(String.t(), atom(), map() | nil) ::
          :ok | {:error, :method_unsupported}
  def supports_method?(_method, :local_only, nil), do: {:error, :method_unsupported}
  def supports_method?(_method, _category, nil), do: :ok

  def supports_method?(method, category, capabilities)
      when is_binary(method) and is_atom(category) and is_map(capabilities) do
    unsupported_categories =
      Map.get(capabilities, :unsupported_categories, @default_unsupported_categories) || []

    unsupported_methods = Map.get(capabilities, :unsupported_methods) || []

    cond do
      method in unsupported_methods ->
        {:error, :method_unsupported}

      category in unsupported_categories ->
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
  @spec validate_params(String.t(), term(), map() | nil, map()) :: :ok | {:error, term()}
  def validate_params(_method, _params, nil, _ctx), do: :ok

  def validate_params(method, params, capabilities, ctx) when is_map(capabilities) do
    limits = Map.get(capabilities, :limits) || %{}
    validate_limits(method, validation_params(params), limits, ctx)
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

    if is_list(rules) do
      rules
      |> Enum.take(@max_error_rules)
      |> evaluate_error_rules(code, message, 0)
    else
      :default
    end
  end

  @doc """
  Validates capability declarations before publication. Raises on invalid config.
  """
  @spec validate!(String.t(), map() | nil) :: :ok
  def validate!(_provider_id, nil), do: :ok

  def validate!(provider_id, capabilities) when is_map(capabilities) do
    validate_method_list!(
      provider_id,
      "unsupported_methods",
      Map.get(capabilities, :unsupported_methods, [])
    )

    validate_unsupported_categories!(provider_id, capabilities)
    validate_error_rules!(provider_id, capabilities)
    validate_limits!(provider_id, capabilities)
    :ok
  end

  def validate!(provider_id, capabilities) do
    raise "Provider #{inspect(provider_id)}: capabilities must be a map or null, got: #{inspect(capabilities)}"
  end

  # --- Private ---

  defp validate_limits(method, params, limits, ctx) do
    with :ok <- maybe_validate_block_range(method, params, limits, ctx) do
      maybe_validate_block_age(method, params, limits, ctx)
    end
  end

  defp validation_params(params) when is_map(params), do: [params]
  defp validation_params(params), do: params

  defp maybe_validate_block_range("eth_getLogs", params, %{max_block_range: limit}, ctx)
       when is_integer(limit) do
    AdapterHelpers.validate_block_range(params, ctx, limit)
  end

  defp maybe_validate_block_range(_method, _params, _limits, _ctx), do: :ok

  defp maybe_validate_block_age(method, params, limits, ctx) do
    max_age = Map.get(limits, :max_block_age)
    age_methods = Map.get(limits, :block_age_methods) || []

    if max_age && method in age_methods do
      AdapterHelpers.validate_block_age(method, params, ctx, max_age)
    else
      :ok
    end
  end

  defp evaluate_error_rules([], _code, _message, _index), do: :default

  defp evaluate_error_rules([rule | rest], code, message, index) do
    if rule_matches?(code, message, rule) do
      :telemetry.execute(
        [:lasso, :capabilities, :error_rule_match],
        %{count: 1},
        %{rule_index: index, category: rule.category}
      )

      {:ok, rule.category}
    else
      evaluate_error_rules(rest, code, message, index + 1)
    end
  end

  defp rule_matches?(code, message, rule) when is_map(rule) do
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

  defp rule_matches?(_code, _message, _rule), do: false

  defp rule_code_matches?(code, %{code: rule_code}), do: code == rule_code
  defp rule_code_matches?(_code, _rule), do: false

  defp rule_message_matches?(nil, _rule), do: false

  defp rule_message_matches?(message, %{message_contains: patterns}) when is_list(patterns) do
    lower = String.downcase(message)

    patterns
    |> Enum.take(@max_message_patterns_per_rule)
    |> Enum.any?(&valid_pattern_match?(lower, &1))
  end

  defp rule_message_matches?(message, %{message_contains: pattern}) when is_binary(pattern) do
    valid_pattern_match?(String.downcase(message), pattern)
  end

  defp rule_message_matches?(_message, _rule), do: false

  defp valid_pattern_match?(message_lower, pattern) when is_binary(pattern) do
    pattern = String.trim(pattern)

    byte_size(pattern) > 0 and byte_size(pattern) <= @max_message_pattern_bytes and
      String.contains?(message_lower, String.downcase(pattern))
  end

  defp valid_pattern_match?(_message_lower, _pattern), do: false

  # --- Boot-time schema validation ---

  defp validate_unsupported_categories!(provider_id, capabilities) do
    categories = Map.get(capabilities, :unsupported_categories, [])

    unless is_list(categories) do
      raise "Provider #{inspect(provider_id)}: unsupported_categories must be a list."
    end

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

    unless is_list(rules) do
      raise "Provider #{inspect(provider_id)}: error_rules must be a list."
    end

    if length(rules) > @max_error_rules do
      raise "Provider #{inspect(provider_id)}: error_rules exceeds the maximum of #{@max_error_rules}."
    end

    Enum.with_index(rules, fn rule, idx ->
      unless is_map(rule) do
        raise "Provider #{inspect(provider_id)}: error_rules[#{idx}] must be a map."
      end

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

      validate_error_code_type!(provider_id, idx, rule)
      validate_message_contains_type!(provider_id, idx, rule)
    end)
  end

  defp validate_error_code_type!(provider_id, idx, rule) do
    case Map.fetch(rule, :code) do
      :error ->
        :ok

      {:ok, code} when is_integer(code) ->
        :ok

      {:ok, code} ->
        raise """
        Provider "#{provider_id}": error_rules[#{idx}].code must be an integer, \
        got: #{inspect(code)}
        """
    end
  end

  defp validate_message_contains_type!(provider_id, idx, rule) do
    case Map.fetch(rule, :message_contains) do
      :error ->
        :ok

      {:ok, val} when is_binary(val) ->
        validate_message_pattern!(provider_id, idx, val)

      {:ok, val} when is_list(val) ->
        cond do
          val == [] ->
            raise "Provider \"#{provider_id}\": error_rules[#{idx}].message_contains must contain at least one pattern."

          length(val) > @max_message_patterns_per_rule ->
            raise "Provider \"#{provider_id}\": error_rules[#{idx}].message_contains exceeds #{@max_message_patterns_per_rule} patterns."

          not Enum.all?(val, &is_binary/1) ->
            raise """
            Provider "#{provider_id}": error_rules[#{idx}].message_contains list must \
            contain only strings, got: #{inspect(val)}
            """

          true ->
            Enum.each(val, &validate_message_pattern!(provider_id, idx, &1))
        end

      {:ok, val} ->
        raise """
        Provider "#{provider_id}": error_rules[#{idx}].message_contains must be a \
        string or list of strings, got: #{inspect(val)}
        """
    end
  end

  defp validate_message_pattern!(provider_id, idx, pattern) do
    cond do
      String.trim(pattern) == "" ->
        raise "Provider \"#{provider_id}\": error_rules[#{idx}].message_contains patterns must not be empty."

      byte_size(pattern) > @max_message_pattern_bytes ->
        raise "Provider \"#{provider_id}\": error_rules[#{idx}].message_contains patterns must be at most #{@max_message_pattern_bytes} bytes."

      true ->
        :ok
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

    validate_method_list!(
      provider_id,
      "limits.block_age_methods",
      Map.get(limits, :block_age_methods, [])
    )
  end

  defp validate_method_list!(provider_id, field, methods) do
    unless is_list(methods) and Enum.all?(methods, &is_binary/1) do
      raise "Provider #{inspect(provider_id)}: #{field} must be a list of strings."
    end
  end
end
