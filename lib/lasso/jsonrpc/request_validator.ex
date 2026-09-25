defmodule Lasso.JSONRPC.RequestValidator do
  @moduledoc false

  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.JSONRPC.MethodParamsValidator

  @jsonrpc_version "2.0"

  @type id :: number() | String.t() | nil
  @type validation_result :: {:ok, map()} | {:invalid, JError.t(), id()}

  @spec validate(term()) :: validation_result()
  def validate(request) when is_map(request) do
    response_id = response_id(request)

    cond do
      request["jsonrpc"] != @jsonrpc_version ->
        invalid_request("jsonrpc must be \"2.0\"", response_id)

      not is_binary(request["method"]) ->
        invalid_request("method must be a string", response_id)

      not valid_id?(request) ->
        invalid_request("id must be a string, number, or null", nil)

      not valid_params?(request) ->
        {:invalid, JError.new(-32_602, "Invalid params: expected an array or object"),
         response_id}

      true ->
        request = Map.put_new(request, "params", [])

        case MethodParamsValidator.validate(request["method"], request["params"]) do
          :ok -> {:ok, request}
          {:error, error} -> {:invalid, error, response_id}
        end
    end
  end

  def validate(_request), do: invalid_request(nil, nil)

  @spec notification?(term()) :: boolean()
  def notification?(request) when is_map(request) do
    not Map.has_key?(request, "id") and
      request["jsonrpc"] == @jsonrpc_version and
      is_binary(request["method"]) and
      valid_params?(request)
  end

  def notification?(_request), do: false

  defp invalid_request(nil, response_id),
    do: {:invalid, JError.new(-32_600, "Invalid Request"), response_id}

  defp invalid_request(detail, response_id),
    do: {:invalid, JError.new(-32_600, "Invalid Request: " <> detail), response_id}

  defp response_id(request) do
    case Map.fetch(request, "id") do
      {:ok, id} when is_binary(id) or is_number(id) or is_nil(id) -> id
      _missing_or_invalid -> nil
    end
  end

  defp valid_id?(request) do
    case Map.fetch(request, "id") do
      :error -> true
      {:ok, id} -> is_binary(id) or is_number(id) or is_nil(id)
    end
  end

  defp valid_params?(request) do
    case Map.fetch(request, "params") do
      :error -> true
      {:ok, params} -> is_list(params) or is_map(params)
    end
  end
end
