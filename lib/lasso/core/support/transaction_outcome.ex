defmodule Lasso.Core.Support.TransactionOutcome do
  @moduledoc """
  Stop or fail over an identical signed transaction. Wording never proves success.

  The stop list covers rejections that another upstream would repeat for the
  same signed bytes. Nonce-too-high stops, and every unlisted rejection fails
  over, regardless of the client's validation order or JSON-RPC code. A hash
  lookup after the final rejection, not this list, decides whether the
  transaction was accepted.
  """

  alias Lasso.Core.Support.{ErrorClassification, ErrorResolution}

  # Wording is drawn from execution client sources and captured gateway rewrites.
  @rules [
    # geth, reth, Erigon, Nethermind and Besu.
    {:already_known, :stop, ["already known", "existing txn with same hash"]},
    # Includes the Arbitrum Nitro sequencer and Besu -32001.
    {:nonce_low, :stop, ["nonce too low", "nonce is too low", "nonce has already been used"]},
    {:nonce_high, :stop, ["nonce too high"]},
    # Balance-before-nonce clients still get the evidence lookup.
    {:insufficient_funds, :stop,
     [
       "insufficient funds",
       "insufficient balance for transfer",
       "upfront gas cost exceeds account balance"
     ]},
    # All execution client families.
    {:intrinsic_gas, :stop,
     [
       "intrinsic gas too low",
       "intrinsicgas",
       "intrinsic gas exceeds gas limit",
       "floor data gas",
       "gas below floor data cost"
     ]},
    # Nethermind's enum and Besu's fixed message included.
    {:tip_above_cap, :stop,
     [
       "max priority fee per gas higher than max fee per gas",
       "max priority fee per gas exceeds max fee per gas",
       "invalidmaxpriorityfeepergas"
     ]},
    # Arbitrum Nitro prechecker and sequencer.
    {:fee_cap, :stop,
     ["max fee per gas less than block base fee", "fee cap less than block base fee"]},
    # All execution client families.
    {:invalid_sender, :stop,
     [
       "invalid sender",
       "invalid chain id",
       "tx for different chain",
       "wrong chainid",
       "invalidtxchainid",
       "invalid transaction signature",
       "invalidtxsignature",
       "invalid signature",
       "failed to recover sender",
       "invalid transaction v, r, s values"
     ]},
    # Client RLP errors and gateway rewrites; Besu's misleading block wording is
    # an RLP rejection.
    {:malformed_rlp, :stop,
     [
       "rlp:",
       "typed transaction too short",
       "failed to decode signed transaction",
       "empty transaction data",
       "invalid rlp",
       "short input",
       "trailing bytes",
       "input too short",
       "unmarshal transaction failed",
       "reading transaction object failed",
       "long list prefix used for short list",
       "invalid block param (block not found)"
     ]},
    # Includes unknown-type decoder variants.
    {:unsupported_type, :stop,
     [
       "transaction type not supported",
       "unsupported transaction type",
       "invalid transaction type",
       "unknown transaction type",
       "typed transaction has unknown type",
       "unexpected tx type",
       "fork supporting this transaction type is not activated"
     ]},
    # Includes Besu's -32005 collision.
    {:block_gas_limit, :stop,
     [
       "exceeds block gas limit",
       "gas limit exceeds block gas limit",
       "gas limit is too high",
       "transaction gas limit too high",
       "gas limit too high",
       "transaction gas limit cap exceeded",
       "txgaslimitcapexceeded",
       "gas limit reached"
     ]},
    # Replacement precedes bare underpriced.
    {:replacement_underpriced, :failover,
     ["replacement transaction underpriced", "could not replace existing tx"]},
    {:underpriced, :failover,
     [
       "underpriced",
       "transaction gas price below minimum",
       "priority fee below minimum",
       "gas price below configured minimum gas price",
       "fee too low"
     ]},
    # Account slot, subpool and delegation limits.
    {:pool_capacity, :failover,
     [
       "txpool is full",
       "sub-pool is full",
       "blobs limit in txpool is full",
       "spammer",
       "account limit exceeded",
       "address already reserved",
       "pending transaction type conflict",
       "future transaction tries to replace pending",
       "in-flight transaction limit reached",
       "gapped-nonce tx",
       "gapped-nonce transaction",
       "delegation nonce gap",
       "authority already reserved",
       "delegation authority has pending transaction"
     ]},
    # Managed-provider throughput wording.
    {:capacity, :failover, ["rate limit", "compute units per second", "request rate exceeded"]}
  ]

  @spec classify(integer() | nil, binary() | nil) :: {:stop | :failover, atom()}
  def classify(code, message) do
    message = String.downcase(message || "")

    cond do
      Regex.match?(~r/\bknown transaction\b/, message) ->
        {:stop, :already_known}

      rule =
          Enum.find(@rules, fn {reason, _, patterns} ->
            Enum.any?(patterns, &String.contains?(message, &1)) and
                (reason != :insufficient_funds or not provider_account_refusal?(message))
          end) ->
        {reason, action, _} = rule
        {action, reason}

      ErrorClassification.quota_exhausted?(message) ->
        {:failover, :capacity}

      code in [429, -32_005] ->
        {:failover, :capacity}

      true ->
        {:failover, :other}
    end
  end

  @doc "Explicit error properties that bypass the generic classifier."
  @spec error_options(integer() | nil, binary() | nil) :: keyword()
  def error_options(code, message) do
    {action, reason} = classify(code, message)

    [category: category(action, reason), retriable?: action == :failover, breaker_penalty?: false]
  end

  @doc "Project a transaction rejection into canonical attempt control properties."
  @spec resolve(integer() | nil, binary() | nil, keyword()) :: ErrorResolution.t()
  def resolve(code, message, opts) do
    properties = error_options(code, message)
    {_action, reason} = classify(code, message)
    category = properties[:category]

    %ErrorResolution{
      code: code,
      category: category,
      control_category: category,
      shared_control?: false,
      classification_path: :transaction_outcome,
      baseline_category: category,
      baseline_path: reason,
      retriable?: properties[:retriable?],
      breaker_penalty?: false,
      provider_health_failure?: reason == :capacity,
      scope: %{
        profile: opts[:profile],
        chain_id: opts[:chain_id],
        provider_id: opts[:provider_id]
      }
    }
  end

  defp category(:stop, _reason), do: :deterministic
  defp category(:failover, :capacity), do: :quota
  defp category(:failover, _reason), do: :ambiguous

  @doc "Normalize a sendRaw transport failure without applying JSON-RPC code fallbacks."
  @spec transport_error(term(), keyword()) :: Lasso.JSONRPC.Error.t()
  def transport_error(%Lasso.JSONRPC.Error{} = error, opts) do
    resolution = resolve(error.code, error.message, opts)

    %{
      error
      | category: resolution.category,
        retriable?: resolution.retriable?,
        breaker_penalty?: false,
        resolution: resolution
    }
  end

  def transport_error({:rate_limit, _payload} = reason, opts) do
    error = Lasso.Core.Support.ErrorNormalizer.normalize(reason, opts)

    resolution = %{
      resolve(-32_005, "Rate limited by provider", opts)
      | category: :rate_limit,
        control_category: :rate_limit,
        baseline_category: :rate_limit
    }

    %{
      error
      | category: :rate_limit,
        retriable?: true,
        breaker_penalty?: false,
        resolution: resolution
    }
  end

  def transport_error(reason, opts) do
    {code, message, payload} =
      case reason do
        {:server_error, payload} -> {-32_000, "Upstream server error", payload}
        {:client_error, payload} -> {-32_000, "Upstream rejected request", payload}
        :timeout -> {-32_004, "Upstream timeout", %{}}
        _ -> {-32_004, "Upstream transport failed", %{}}
      end

    payload = if is_map(payload), do: payload, else: %{}
    error = Lasso.Core.Transport.UpstreamResponse.gateway_error(payload[:body])

    {code, message, data, classification_message, rejection_body} =
      case error do
        {:ok, c, m, data} ->
          {c, m, data, m, nil}

        _ ->
          {code, message, Map.take(payload, [:status]), payload[:body] || message, payload[:body]}
      end

    resolution =
      resolve(code, classification_message, Keyword.put(opts, :http_status, payload[:status]))

    data =
      case payload[:retry_after_ms] do
        delay when is_integer(delay) ->
          data |> data_map() |> Map.delete("retry_after_ms") |> Map.put(:retry_after_ms, delay)

        _ ->
          data
      end

    Lasso.JSONRPC.Error.new(
      code,
      message,
      [
        data: data,
        provider_id: opts[:provider_id],
        transport: opts[:transport],
        http_status: payload[:status],
        source: :transport,
        resolution: resolution,
        # Retain unknown plaintext only for masked observation. sendRaw's final
        # hint clears raw_response before either ingress can serialize it.
        raw_response: if(resolution.baseline_path == :other, do: rejection_body)
      ] ++
        [
          category: resolution.category,
          retriable?: resolution.retriable?,
          breaker_penalty?: false
        ]
    )
  end

  @doc "The matched table row retained without storing rejection text."
  @spec reason(Lasso.JSONRPC.Error.t()) :: atom()
  def reason(%{
        resolution: %ErrorResolution{
          classification_path: :transaction_outcome,
          baseline_path: reason
        }
      }),
      do: reason

  def reason(error), do: elem(classify(error.code, error.message), 1)

  @doc "Preserve scalar upstream error data when adding Lasso's hints."
  @spec data_map(term()) :: map()
  def data_map(nil), do: %{}
  def data_map(data) when is_map(data), do: data
  def data_map(data), do: %{upstream_data: data}

  @doc "The retained, bounded Retry-After hint, if present."
  @spec retry_after(Lasso.JSONRPC.Error.t()) :: non_neg_integer() | nil
  def retry_after(%{data: data}) when is_map(data) do
    case data[:retry_after_ms] || data["retry_after_ms"] do
      delay when is_integer(delay) and delay >= 0 -> delay
      _ -> nil
    end
  end

  def retry_after(_), do: nil

  @doc "Hash for evidence lookup only; opaque chain-specific types pass through."
  @spec hash(term()) :: binary() | nil
  def hash(["0x" <> raw]) do
    case Base.decode16(raw, case: :mixed) do
      {:ok, bytes} -> "0x" <> Base.encode16(ExKeccak.hash_256(hash_payload(bytes)), case: :lower)
      :error -> nil
    end
  end

  def hash(_), do: nil

  # Decode only enough RLP to find the first item of an EIP-4844 network
  # wrapper. The signed payload's original bytes are hashed, never reencoded.
  defp hash_payload(<<3, outer::binary>> = bytes) do
    with {:ok, :list, body, <<>>} <- rlp_item(outer),
         {:ok, :list, _payload, rest} <- rlp_item(body) do
      <<3>> <> binary_part(body, 0, byte_size(body) - byte_size(rest))
    else
      _ -> bytes
    end
  end

  defp hash_payload(bytes), do: bytes

  defp rlp_item(<<tag, rest::binary>>) when tag in 0xC0..0xF7,
    do: take_item(:list, rest, tag - 0xC0)

  defp rlp_item(<<tag, rest::binary>>) when tag in 0xF8..0xFF do
    length_size = tag - 0xF7

    with <<length::binary-size(length_size), body::binary>> <- rest,
         do: take_item(:list, body, :binary.decode_unsigned(length))
  end

  defp rlp_item(_), do: :error

  defp take_item(kind, bytes, size) when size <= byte_size(bytes) do
    <<body::binary-size(size), rest::binary>> = bytes
    {:ok, kind, body, rest}
  end

  defp take_item(_, _, _), do: :error

  # A resend of identical signed bytes is safe, so account top-up advice fails
  # over here even though reads keep it terminal.
  defp provider_account_refusal?(message),
    do: ErrorClassification.provider_billing?(message) or message =~ ~r/\btop[- ]?up\b/
end
