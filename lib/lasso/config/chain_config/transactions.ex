defmodule Lasso.Config.ChainConfig.Transactions do
  @moduledoc "Chain-level relay boundary for transaction broadcasts."
  @derive Jason.Encoder
  defstruct relays: [], public_fallback: false

  @type t :: %__MODULE__{relays: [String.t()], public_fallback: boolean()}

  @spec parse(term()) :: t() | nil
  def parse(nil), do: nil
  def parse(%__MODULE__{} = policy), do: policy

  def parse(attrs) when is_map(attrs) do
    %__MODULE__{
      relays: Map.get(attrs, :relays, Map.get(attrs, "relays", [])),
      public_fallback: Map.get(attrs, :public_fallback, Map.get(attrs, "public_fallback", false))
    }
  end

  def parse(_), do: %__MODULE__{}

  @spec validate(term(), [map()]) :: :ok | {:error, :invalid_transactions}
  def validate(nil, _providers), do: :ok

  def validate(%__MODULE__{relays: relays, public_fallback: fallback}, providers)
      when is_list(relays) and relays != [] and is_boolean(fallback) do
    ids = Enum.map(providers, & &1.id)

    valid? =
      Enum.all?(relays, &(is_binary(&1) and &1 in ids)) and
        length(Enum.uniq(relays)) == length(relays) and Enum.any?(ids, &(&1 not in relays)) and
        Enum.all?(providers, fn provider ->
          provider.id not in relays or send_capable?(provider.capabilities)
        end)

    if valid?, do: :ok, else: {:error, :invalid_transactions}
  end

  def validate(_, _), do: {:error, :invalid_transactions}

  defp send_capable?(nil), do: true

  defp send_capable?(caps) when is_map(caps) do
    methods = Map.get(caps, :unsupported_methods, Map.get(caps, "unsupported_methods", [])) || []

    categories =
      Map.get(caps, :unsupported_categories, Map.get(caps, "unsupported_categories", [])) || []

    is_list(methods) and is_list(categories) and "eth_sendRawTransaction" not in methods and
      Enum.all?([:mempool, "mempool"], &(&1 not in categories))
  end

  defp send_capable?(_), do: false
end
