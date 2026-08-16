defmodule Lasso.RPC.PreparedRequest do
  @moduledoc """
  Encoded JSON-RPC request data shared by transport attempts.

  The encoded body carries a request-private transport identifier. Transports
  validate responses against that identifier and restore `client_id` before
  returning the response to the caller.
  """

  alias Lasso.Core.Transport.UpstreamResponse

  @enforce_keys [:transport_id, :client_id, :encoded]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          transport_id: String.t(),
          client_id: term(),
          encoded: binary()
        }

  @spec new(map(), String.t()) :: {:ok, t()} | {:error, term()}
  def new(rpc_request, transport_id)
      when is_map(rpc_request) and is_binary(transport_id) do
    client_id = Map.get(rpc_request, "id")

    cond do
      not UpstreamResponse.transport_id?(transport_id) ->
        {:error, :invalid_transport_id}

      not valid_client_id?(client_id) ->
        {:error, :invalid_client_id}

      true ->
        case encode_request(Map.put(rpc_request, "id", transport_id)) do
          {:ok, encoded} ->
            {:ok,
             %__MODULE__{
               transport_id: transport_id,
               client_id: client_id,
               encoded: encoded
             }}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc false
  @spec to_legacy_map(t()) :: {:ok, map()} | {:error, term()}
  def to_legacy_map(%__MODULE__{encoded: encoded, client_id: client_id}) do
    with {:ok, rpc_request} <- Jason.decode(encoded) do
      {:ok, Map.put(rpc_request, "id", client_id)}
    end
  end

  defp valid_client_id?(client_id),
    do: is_binary(client_id) or is_integer(client_id) or is_nil(client_id)

  defp encode_request(rpc_request) do
    {:ok, rpc_request |> :json.encode(&encode_json_value/2) |> IO.iodata_to_binary()}
  rescue
    _error -> Jason.encode(rpc_request)
  catch
    _kind, _reason -> Jason.encode(rpc_request)
  end

  defp encode_json_value(nil, _encoder), do: "null"
  defp encode_json_value(value, encoder), do: :json.encode_value(value, encoder)
end
