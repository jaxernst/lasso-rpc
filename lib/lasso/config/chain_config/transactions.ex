defmodule Lasso.Config.ChainConfig.Transactions do
  @moduledoc "Chain-level relay boundary for transaction broadcasts."
  @derive Jason.Encoder
  defstruct providers: [], fallback: "none"

  @type t :: %__MODULE__{providers: [String.t()], fallback: String.t()}

  @spec parse(term()) :: t() | nil
  def parse(nil), do: nil
  def parse(%__MODULE__{} = policy), do: policy

  def parse(attrs) when is_map(attrs) do
    %__MODULE__{
      providers: Map.get(attrs, :providers, Map.get(attrs, "providers", [])),
      fallback: Map.get(attrs, :fallback, Map.get(attrs, "fallback", "none"))
    }
  end

  def parse(_), do: %__MODULE__{}

  @spec validate(term(), [map()]) :: :ok | {:error, :invalid_transactions}
  def validate(nil, _providers), do: :ok

  def validate(%__MODULE__{providers: transaction_providers, fallback: fallback}, providers)
      when is_list(transaction_providers) and transaction_providers != [] and
             fallback in ["none", "read_providers"] do
    ids = Enum.map(providers, & &1.id)

    valid? =
      Enum.all?(transaction_providers, &(is_binary(&1) and &1 in ids)) and
        length(Enum.uniq(transaction_providers)) == length(transaction_providers) and
        Enum.any?(ids, &(&1 not in transaction_providers)) and
        Enum.all?(providers, fn provider ->
          provider.id not in transaction_providers or send_capable?(provider.capabilities)
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
