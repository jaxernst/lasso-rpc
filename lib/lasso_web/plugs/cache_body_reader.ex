defmodule LassoWeb.Plugs.CacheBodyReader do
  @moduledoc """
  Custom body reader that caches raw body for webhook signature verification.

  Only caches body for paths that need it (e.g., /webhooks/*).
  """

  @cache_paths ["/webhooks/"]

  def read_body(conn, opts) do
    if should_cache?(conn.request_path) do
      {:ok, body, conn} = Plug.Conn.read_body(conn, opts)
      conn = Plug.Conn.assign(conn, :raw_body, body)
      {:ok, body, conn}
    else
      Plug.Conn.read_body(conn, opts)
    end
  end

  defp should_cache?(path) do
    Enum.any?(@cache_paths, &String.starts_with?(path, &1))
  end
end
