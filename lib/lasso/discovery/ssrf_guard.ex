defmodule Lasso.Discovery.SSRFGuard do
  @moduledoc """
  Validates user-supplied URLs against SSRF attacks.

  Resolves DNS and blocks requests to private, loopback, link-local,
  and cloud metadata IP ranges.

  The resolver returns the complete validated answer set. Stateful and
  account-owned transports connect directly to those address tuples while
  retaining the original hostname as their HTTP and TLS authority.
  """

  import Bitwise

  @blocked_ipv4_ranges [
    # Loopback
    {127, 0, 0, 0, 8},
    # 10.0.0.0/8
    {10, 0, 0, 0, 8},
    # 172.16.0.0/12
    {172, 16, 0, 0, 12},
    # 192.168.0.0/16
    {192, 168, 0, 0, 16},
    # Link-local
    {169, 254, 0, 0, 16},
    # Current network
    {0, 0, 0, 0, 8},
    # Carrier-grade NAT
    {100, 64, 0, 0, 10},
    # IETF protocol assignments / documentation ranges
    {192, 0, 0, 0, 24},
    {192, 0, 2, 0, 24},
    {198, 51, 100, 0, 24},
    {203, 0, 113, 0, 24},
    # Benchmarking, multicast, reserved, and limited broadcast
    {198, 18, 0, 0, 15},
    {224, 0, 0, 0, 4},
    {240, 0, 0, 0, 4}
  ]

  @blocked_ipv6_prefixes [
    # Loopback ::1
    {0, 0, 0, 0, 0, 0, 0, 1},
    # Unspecified ::
    {0, 0, 0, 0, 0, 0, 0, 0}
  ]

  # Fly.io internal network
  @fly_internal_prefix {0xFDAA, 0, 0, 0, 0, 0, 0, 0}

  @spec validate_url(String.t()) :: {:ok, String.t()} | {:error, :ssrf_blocked, String.t()}
  def validate_url(url) when is_binary(url) do
    validate_url(url, &resolve_public_addresses/1)
  end

  @doc "Validates a URL with an injected resolver using the same fail-closed policy."
  @spec validate_url(String.t(), (String.t() -> {:ok, [:inet.ip_address()]} | tuple())) ::
          {:ok, String.t()} | {:error, :ssrf_blocked, String.t()}
  def validate_url(url, resolver) when is_binary(url) and is_function(resolver, 1) do
    case resolve_url(url, resolver) do
      {:ok, _uri, _addresses} -> {:ok, url}
      {:error, :ssrf_blocked, _reason} = error -> error
    end
  end

  @doc "Resolves and validates a URL once, returning the address set approved for direct connection."
  @spec resolve_url(String.t(), (String.t() -> {:ok, [:inet.ip_address()]} | tuple())) ::
          {:ok, URI.t(), [:inet.ip_address()]} | {:error, :ssrf_blocked, String.t()}
  def resolve_url(url, resolver) when is_binary(url) and is_function(resolver, 1) do
    with {:ok, uri} <- parse_uri(url),
         :ok <- validate_scheme(uri),
         {:ok, addresses} <- resolve_host(uri.host, resolver) do
      {:ok, uri, addresses}
    end
  end

  @doc "Resolves a configured upstream URL once without restricting private network addresses."
  @spec resolve_configured_url(
          String.t(),
          (String.t() -> {:ok, [:inet.ip_address()]} | tuple())
        ) ::
          {:ok, URI.t(), [:inet.ip_address()]} | {:error, :ssrf_blocked, String.t()}
  def resolve_configured_url(url, resolver) when is_binary(url) and is_function(resolver, 1) do
    with {:ok, uri} <- parse_uri(url),
         :ok <- validate_scheme(uri),
         {:ok, addresses} <- resolve_configured_host(uri.host, resolver) do
      {:ok, uri, addresses}
    end
  end

  defp parse_uri(url) do
    case URI.parse(url) do
      %URI{host: nil} -> {:error, :ssrf_blocked, "Missing host"}
      %URI{host: ""} -> {:error, :ssrf_blocked, "Empty host"}
      uri -> {:ok, uri}
    end
  end

  defp validate_scheme(%URI{scheme: scheme}) when scheme in ["http", "https", "ws", "wss"],
    do: :ok

  defp validate_scheme(%URI{scheme: scheme}),
    do: {:error, :ssrf_blocked, "Blocked scheme: #{scheme}"}

  defp resolve_host(host, resolver) do
    if String.ends_with?(host, ".internal") do
      {:error, :ssrf_blocked, "Internal domain blocked"}
    else
      case resolver.(host) do
        {:ok, addresses} when is_list(addresses) and addresses != [] -> {:ok, addresses}
        {:ok, []} -> {:error, :ssrf_blocked, "DNS resolution returned no addresses"}
        {:error, :ssrf_blocked, _reason} = error -> error
        _other -> {:error, :ssrf_blocked, "Invalid DNS resolver result"}
      end
    end
  end

  defp resolve_configured_host(host, resolver) do
    case resolver.(host) do
      {:ok, addresses} when is_list(addresses) and addresses != [] ->
        if Enum.all?(addresses, &valid_address?/1) do
          {:ok, addresses}
        else
          {:error, :ssrf_blocked, "Invalid DNS address"}
        end

      {:ok, []} ->
        {:error, :ssrf_blocked, "DNS resolution returned no addresses"}

      {:error, :ssrf_blocked, _reason} = error ->
        error

      _other ->
        {:error, :ssrf_blocked, "Invalid DNS resolver result"}
    end
  end

  @doc "Resolves every IPv4 and IPv6 address for a configured upstream host."
  @spec resolve_addresses(String.t()) ::
          {:ok, [:inet.ip_address()]} | {:error, :ssrf_blocked, String.t()}
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
      [] -> {:error, :ssrf_blocked, "DNS resolution failed for #{host}"}
      addresses -> {:ok, addresses}
    end
  end

  @doc "Resolves every IPv4 and IPv6 address for a host and returns them only when all are public."
  @spec resolve_public_addresses(String.t()) ::
          {:ok, [:inet.ip_address()]} | {:error, :ssrf_blocked, String.t()}
  def resolve_public_addresses(host) when is_binary(host) do
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
      [] ->
        {:error, :ssrf_blocked, "DNS resolution failed for #{host}"}

      addresses ->
        case validate_resolved_addresses(addresses) do
          :ok -> {:ok, addresses}
          {:error, :ssrf_blocked, _reason} = error -> error
        end
    end
  end

  @doc "Validates a complete DNS answer set, rejecting the set when any address is blocked."
  @spec validate_resolved_addresses([:inet.ip_address()]) ::
          :ok | {:error, :ssrf_blocked, String.t()}
  def validate_resolved_addresses(addresses) when is_list(addresses) do
    Enum.reduce_while(addresses, :ok, fn address, :ok ->
      case check_address(address) do
        :ok -> {:cont, :ok}
        {:error, :ssrf_blocked, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp check_address({_, _, _, _} = ip), do: check_ipv4(ip)
  defp check_address({_, _, _, _, _, _, _, _} = ip), do: check_ipv6(ip)

  defp valid_address?({a, b, c, d}),
    do: Enum.all?([a, b, c, d], &(is_integer(&1) and &1 in 0..255))

  defp valid_address?({a, b, c, d, e, f, g, h}),
    do: Enum.all?([a, b, c, d, e, f, g, h], &(is_integer(&1) and &1 in 0..65_535))

  defp valid_address?(_other), do: false

  defp check_ipv4(ip) do
    if ipv4_blocked?(ip) do
      {:error, :ssrf_blocked, "Blocked IP: #{:inet.ntoa(ip)}"}
    else
      :ok
    end
  end

  defp check_ipv6(ip) do
    if ipv6_blocked?(ip) do
      {:error, :ssrf_blocked, "Blocked IP: #{:inet.ntoa(ip)}"}
    else
      :ok
    end
  end

  defp ipv4_blocked?({a, b, c, d}) do
    Enum.any?(@blocked_ipv4_ranges, fn {ra, rb, rc, rd, prefix_len} ->
      mask = bsl(0xFFFFFFFF, 32 - prefix_len) |> band(0xFFFFFFFF)
      ip_int = bsl(a, 24) + bsl(b, 16) + bsl(c, 8) + d
      range_int = bsl(ra, 24) + bsl(rb, 16) + bsl(rc, 8) + rd
      band(ip_int, mask) == band(range_int, mask)
    end)
  end

  defp ipv6_blocked?(ip) do
    exact_ipv6_blocked?(ip) or local_ipv6_blocked?(ip) or transitional_ipv6_blocked?(ip)
  end

  defp exact_ipv6_blocked?(ip) do
    Enum.any?(@blocked_ipv6_prefixes, fn blocked -> ip == blocked end)
  end

  defp local_ipv6_blocked?({a, _b, _c, _d, _e, _f, _g, _h}) do
    {fly_a, _, _, _, _, _, _, _} = @fly_internal_prefix

    link_local = band(a, 0xFFC0) == 0xFE80
    fly_internal = a == fly_a
    ula = band(a, 0xFE00) == 0xFC00
    multicast = band(a, 0xFF00) == 0xFF00
    site_local = band(a, 0xFFC0) == 0xFEC0

    link_local or fly_internal or ula or multicast or site_local
  end

  defp transitional_ipv6_blocked?({a, b, c, d, e, f, g, h}) do
    nat64 = a == 0x64 and b == 0xFF9B and c == 0 and d == 0 and e == 0 and f == 0
    teredo = a == 0x2001 and b == 0
    six_to_four = a == 0x2002
    ipv4_mapped = ipv4_mapped_blocked?(a, b, c, d, e, f, g, h)

    nat64 or teredo or six_to_four or ipv4_mapped
  end

  defp ipv4_mapped_blocked?(0, 0, 0, 0, 0, 0xFFFF, g, h) do
    ipv4_blocked?({bsr(g, 8), band(g, 0xFF), bsr(h, 8), band(h, 0xFF)})
  end

  defp ipv4_mapped_blocked?(_, _, _, _, _, _, _, _), do: false
end
