defmodule Lasso.Logger.JSONFormatter do
  @moduledoc """
  Bounded, single-line JSON console output for self-hosted log collectors.

  Only stable correlation fields are copied from Logger metadata. Messages
  mask embedded upstream URLs and common credential assignments.
  """

  alias Lasso.URLMask

  @safe_metadata [
    :request_id,
    :chain,
    :chain_id,
    :provider_id,
    :method,
    :transport,
    :status,
    :error_category,
    :duration_ms,
    :profile_id,
    :profile_slug
  ]

  @credential_assignment ~r/(?i)\b(authorization|api[_-]?key|access[_-]?token|secret[_-]?key[_-]?base|secret|password|token)\s*[:=]\s*(?:Bearer\s+)?[^\s,;]+/

  @spec format(Logger.level(), Logger.message(), Logger.metadata(), keyword()) :: IO.chardata()
  def format(level, message, _timestamp, metadata) do
    fields =
      metadata
      |> Keyword.take(@safe_metadata)
      |> Enum.reduce(%{}, fn {key, value}, fields ->
        case safe_value(value) do
          nil -> fields
          safe -> Map.put(fields, Atom.to_string(key), safe)
        end
      end)

    %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      level: Atom.to_string(level),
      message: message |> IO.iodata_to_binary() |> sanitize(),
      metadata: fields
    }
    |> Jason.encode!()
    |> Kernel.<>("\n")
  rescue
    _ -> "{\"level\":\"error\",\"message\":\"log formatting failed\"}\n"
  end

  defp safe_value(value) when is_binary(value), do: sanitize(value)
  defp safe_value(value) when is_integer(value) or is_float(value) or is_boolean(value), do: value
  defp safe_value(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp safe_value(_value), do: nil

  defp sanitize(value) do
    if String.valid?(value) do
      value
      |> URLMask.mask_in_string()
      |> String.replace(@credential_assignment, "[FILTERED_CREDENTIAL]")
    else
      "[INVALID_UTF8]"
    end
  end
end
