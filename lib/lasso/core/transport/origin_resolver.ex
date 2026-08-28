defmodule Lasso.Core.Transport.OriginResolver do
  @moduledoc false

  @type address :: :inet.ip_address()
  @type resolver :: (String.t() -> {:ok, [address()]} | {:error, term()} | tuple())

  @spec resolve(String.t(), resolver()) :: {:ok, [address()]} | {:error, term()}
  def resolve(host, resolver) when is_binary(host) and is_function(resolver, 1) do
    case resolver.(host) do
      {:ok, addresses} when is_list(addresses) and addresses != [] ->
        if Enum.all?(addresses, &valid_address?/1) do
          {:ok, Enum.uniq(addresses)}
        else
          {:error, :invalid_dns_address}
        end

      {:ok, []} ->
        {:error, :empty_dns_answer}

      {:error, _category, reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :invalid_resolver_result}
    end
  end

  @spec resolve_addresses(String.t()) :: {:ok, [address()]} | {:error, term()}
  def resolve_addresses(host) when is_binary(host) do
    host_charlist = String.to_charlist(host)

    addresses =
      [:inet, :inet6]
      |> Enum.flat_map(fn family ->
        case :inet.getaddrs(host_charlist, family) do
          {:ok, resolved} -> resolved
          {:error, _reason} -> []
        end
      end)
      |> Enum.uniq()

    case addresses do
      [] -> {:error, :dns_resolution_failed}
      addresses -> {:ok, addresses}
    end
  end

  defp valid_address?({a, b, c, d}),
    do: Enum.all?([a, b, c, d], &(is_integer(&1) and &1 in 0..255))

  defp valid_address?({a, b, c, d, e, f, g, h}),
    do: Enum.all?([a, b, c, d, e, f, g, h], &(is_integer(&1) and &1 in 0..65_535))

  defp valid_address?(_other), do: false
end
