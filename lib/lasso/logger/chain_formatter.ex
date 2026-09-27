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
  @spec format(Logger.level(), Logger.message(), Logger.metadata(), keyword()) :: IO.chardata()
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
      message |> IO.iodata_to_binary() |> scrub_credentials(),
      metadata_line,
      "\n"
    ]
    |> IO.iodata_to_binary()
    |> Lasso.URLMask.mask_in_string()
  end

  # Render metadata as " => key=value key2=value2" if any keys remain
  defp format_metadata(metadata) when is_list(metadata) do
    # Filter out noisy metadata that clutters logs:
    # - Internal Elixir/Erlang metadata (time, gl, mfa, module, function, file, line)
    # - Process metadata (pid, domain, application)
    filtered =
      Enum.reject(metadata, fn {key, _val} ->
        key in [
          :time,
          :gl,
          :mfa,
          :module,
          :function,
          :file,
          :line,
          :pid,
          :domain,
          :application,
          :__sentry__,
          :sentry
        ]
      end)

    if filtered == [] do
      ""
    else
      rendered =
        filtered
        |> Enum.map(fn {k, v} ->
          value = render_metadata_value(k, v)

          [to_string(k), "=", value]
        end)
        |> Enum.intersperse(" ")

      [" => ", rendered]
    end
  end

  @sensitive_key_tokens [
    "authorization",
    "cookie",
    "token",
    "secret",
    "password",
    "api_key",
    "apikey",
    "x-api-key",
    "private_key",
    "session_id",
    "query_string",
    "account_id",
    "profile_id",
    "user_id",
    "email"
  ]

  defp render_metadata_value(key, value) do
    key_string = key |> to_string() |> String.downcase()

    if Enum.any?(@sensitive_key_tokens, &String.contains?(key_string, &1)) do
      "[REDACTED]"
    else
      case value do
        binary when is_binary(binary) -> scrub_credentials(binary)
        other -> other |> inspect() |> scrub_credentials()
      end
    end
  end

  defp scrub_credentials(value) do
    Regex.replace(~r/\blasso_(?:(?:ak|mk)_)?[A-Za-z0-9_-]{20,}/, value, "lasso_[FILTERED]")
  end
end
