defmodule Lasso.Logger.ChainFormatter do
  @moduledoc """
  Console formatter that prefixes log messages with the target chain when present.

  Usage in config (env-specific):

      config :logger, :console,
        format: {Lasso.Logger.ChainFormatter, :format},
        level: :info,
        metadata: [:chain, :chain_id, :provider, :provider_id, :method, :request_id]
  """

  @doc """
  Format callback used by Logger's console backend.

  Receives log level, message as iodata, timestamp, and a metadata keyword list.
  Returns an iodata line to be written to the console.
  """
  @spec format(Logger.level(), IO.chardata(), Logger.Formatter.time(), keyword()) :: IO.chardata()
  def format(level, message, _timestamp, metadata) do
    chain_prefix =
      case Keyword.get(metadata, :chain) do
        nil -> []
        chain when is_binary(chain) -> ["[", chain, "] "]
        other -> ["[", to_string(other), "] "]
      end

    base_prefix = ["[", to_string(level), "] ", chain_prefix]

    metadata_line = format_metadata(metadata)

    [
      base_prefix,
      IO.iodata_to_binary(message),
      metadata_line,
      "\n"
    ]
  end

  # Render metadata as " => key=value key2=value2" if any keys remain
  defp format_metadata(metadata) when is_list(metadata) do
    # Filter out noisy or internal keys if present
    filtered =
      Enum.reject(metadata, fn {key, _val} ->
        key in [:time, :gl, :mfa, :module, :function, :file, :line]
      end)

    if filtered == [] do
      ""
    else
      rendered =
        filtered
        |> Enum.map(fn {k, v} ->
          value =
            case v do
              binary when is_binary(binary) -> binary
              other -> inspect(other)
            end

          [to_string(k), "=", value]
        end)
        |> Enum.intersperse(" ")

      [" => ", rendered]
    end
  end
end
