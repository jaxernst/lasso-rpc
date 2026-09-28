defmodule Lasso.Discovery.Response do
  @moduledoc "Validates JSON-RPC envelopes before treating discovery responses as evidence."

  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.RPC.Transport.HTTP.Client

  @spec request_decoded(map(), String.t(), list(), keyword()) :: {:ok, map()} | {:error, term()}
  def request_decoded(config, method, params, opts \\ []) do
    with {:ok, response} <-
           Client.request_decoded(config, method, params, Keyword.put(opts, :request_id, 1)) do
      validate(response, 1)
    end
  end

  @spec decode(binary(), integer()) :: {:ok, map()} | {:error, term()}
  def decode(bytes, id) do
    with {:ok, response} <- Jason.decode(bytes), do: validate(response, id)
  end

  @spec validate(term(), integer()) :: {:ok, map()} | {:error, :invalid_rpc_response}
  def validate(%{"jsonrpc" => "2.0", "id" => id} = response, id) do
    case {Map.has_key?(response, "result"), Map.fetch(response, "error")} do
      {true, :error} ->
        {:ok, response}

      {false, {:ok, %{"code" => code, "message" => message}}}
      when is_integer(code) and is_binary(message) ->
        {:ok, response}

      _ ->
        {:error, :invalid_rpc_response}
    end
  end

  def validate(
        %{
          "jsonrpc" => "2.0",
          "id" => nil,
          "error" => %{"code" => code, "message" => message} = error
        } = response,
        id
      )
      when is_integer(id) and is_integer(code) and is_binary(message) do
    if not Map.has_key?(response, "result") and
         JError.new(code, message, data: Map.get(error, "data")).category == :rate_limit,
       do: {:ok, response},
       else: {:error, :invalid_rpc_response}
  end

  def validate(_, _), do: {:error, :invalid_rpc_response}
end
