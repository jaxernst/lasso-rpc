defmodule Lasso.JSON.Decoder do
  @moduledoc false

  @spec decode!(binary()) :: term()
  def decode!(bytes) when is_binary(bytes) do
    decoded =
      try do
        :json.decode(bytes, nil, %{null: nil})
      rescue
        error ->
          reraise ArgumentError,
                  [message: "invalid JSON: #{Exception.message(error)}"],
                  __STACKTRACE__
      end

    case decoded do
      {decoded, nil, ""} -> decoded
      {_decoded, nil, _trailing} -> raise ArgumentError, "invalid trailing JSON data"
    end
  end
end
