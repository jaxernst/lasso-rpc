defmodule Lasso.RPC.Providers.CapabilityObservation do
  @moduledoc """
  Time-bounded probe preferences, separate from operator capability declarations.

  Expiry affects routing eligibility; the original observation remains available
  to reports. No timer, database read, or catalog rebuild is needed for expiry.
  """

  @ttl_seconds 86_400
  @restriction_keys [:unsupported_methods, :unsupported_categories, :limits]
  @category_names ~w(core state network node_admin eip1559 eip4844 mempool filters extended_reads batch debug trace txpool other unknown)a
  @limit_keys [:max_block_range, :max_block_age, :max_batch_size, :block_age_methods]

  @spec capture(map(), integer()) :: map()
  def capture(capabilities, now \\ System.system_time(:second)) do
    observation =
      capabilities
      |> Map.take(@restriction_keys)
      |> Map.put_new(:unsupported_methods, [])
      |> Map.put_new(:unsupported_categories, [])
      |> Map.put_new(:limits, %{})
      |> Map.put(:observed_at, now)
      |> Map.put(:expires_at, now + @ttl_seconds)

    capabilities
    |> Map.drop(@restriction_keys)
    |> Map.put(:observed_capabilities, observation)
  end

  @spec active(map() | nil) :: map()
  def active(%{observed_capabilities: observed} = capabilities) when is_map(observed),
    do: active(capabilities, System.system_time(:second))

  def active(_), do: %{}

  @spec active(map() | nil, integer()) :: map()
  def active(capabilities, now) do
    observation = observation(capabilities)

    if fresh?(observation, now) and valid_shape?(observation), do: observation, else: %{}
  end

  @spec fresh?(map(), integer()) :: boolean()
  def fresh?(%{observed_at: observed, expires_at: expires}, now)
      when is_integer(observed) and is_integer(expires) and is_integer(now) do
    observed <= now and now < expires and expires <= observed + @ttl_seconds
  end

  def fresh?(_, _), do: false

  @doc "Includes the original observation for display, even after routing expiry."
  @spec for_report(map()) :: map()
  def for_report(capabilities) do
    observed = observation(capabilities)

    capabilities
    |> Map.put(
      :unsupported_methods,
      list(capabilities, :unsupported_methods) ++ list(observed, :unsupported_methods)
    )
    |> Map.put(
      :unsupported_categories,
      list(capabilities, :unsupported_categories) ++ list(observed, :unsupported_categories)
    )
    |> Map.put(:limits, Map.merge(map(observed, :limits), map(capabilities, :limits)))
  end

  @doc "Normalizes the bounded observation schema at configuration boundaries."
  @spec decode(map()) :: map()
  def decode(capabilities) do
    case Map.get(
           capabilities,
           :observed_capabilities,
           Map.get(capabilities, "observed_capabilities")
         ) do
      observed when is_map(observed) ->
        normalized =
          observed
          |> known_keys(@restriction_keys ++ [:observed_at, :expires_at])
          |> Map.update(:unsupported_methods, [], fn methods ->
            if is_list(methods),
              do: methods |> Enum.take(256) |> Enum.filter(&is_binary/1),
              else: []
          end)
          |> Map.update(:unsupported_categories, [], fn categories ->
            if is_list(categories),
              do:
                categories
                |> Enum.take(64)
                |> Enum.map(&known_atom(&1, @category_names))
                |> Enum.filter(&(&1 in @category_names)),
              else: []
          end)
          |> Map.update(:limits, %{}, fn limits ->
            if is_map(limits),
              do:
                limits
                |> known_keys(@limit_keys)
                |> Map.take(@limit_keys)
                |> Map.filter(fn {key, value} -> valid_limit?(key, value) end),
              else: %{}
          end)

        capabilities
        |> Map.delete("observed_capabilities")
        |> Map.put(:observed_capabilities, normalized)

      _ ->
        capabilities
    end
  end

  defp observation(capabilities) when is_map(capabilities),
    do: map(capabilities, :observed_capabilities)

  defp observation(_), do: %{}

  defp valid_shape?(observed) do
    limits = Map.get(observed, :limits, %{})

    is_list(Map.get(observed, :unsupported_methods, [])) and
      is_list(Map.get(observed, :unsupported_categories, [])) and is_map(limits) and
      Enum.all?(@limit_keys, fn key ->
        not Map.has_key?(limits, key) or valid_limit?(key, Map.get(limits, key))
      end)
  end

  defp valid_limit?(:block_age_methods, value), do: is_list(value)
  defp valid_limit?(:max_block_age, value), do: is_integer(value) and value >= 0
  defp valid_limit?(_key, value), do: is_integer(value) and value > 0

  defp map(container, key) do
    case Map.get(container, key, Map.get(container, Atom.to_string(key))) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp list(container, key) do
    case Map.get(container, key, Map.get(container, Atom.to_string(key))) do
      value when is_list(value) -> value
      _ -> []
    end
  end

  defp known_keys(map, keys),
    do: Map.new(map, fn {key, value} -> {known_atom(key, keys), value} end)

  defp known_atom(value, keys) when is_binary(value),
    do: Enum.find(keys, value, &(Atom.to_string(&1) == value))

  defp known_atom(value, _), do: value
end
