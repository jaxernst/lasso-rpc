defmodule LassoWeb.Plugs.DowngradeHeadersPlug do
  @moduledoc """
  Injects downgrade awareness headers when a request is routing through
  the free public provider pool instead of the key's configured premium profile.

  Headers added when downgraded:
  - `x-lasso-downgraded: true`
  - `x-lasso-profile: public` (the fallback profile)
  - `x-lasso-balance-warning: true`

  Headers added when strategy is normalized:
  - `x-lasso-effective-strategy: load_balanced|latency_weighted|fastest`
  """

  @behaviour Plug

  alias Lasso.Config.ProfileValidator

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    Plug.Conn.register_before_send(conn, &inject_headers/1)
  end

  defp inject_headers(conn) do
    requested = conn.assigns[:requested_provider_strategy]
    effective = conn.assigns[:provider_strategy]

    conn =
      if requested && effective && requested != effective do
        Plug.Conn.put_resp_header(conn, "x-lasso-effective-strategy", Atom.to_string(effective))
      else
        conn
      end

    if conn.assigns[:downgraded] do
      profile = conn.assigns[:profile_slug] || ProfileValidator.default_profile()

      conn
      |> Plug.Conn.put_resp_header("x-lasso-downgraded", "true")
      |> Plug.Conn.put_resp_header("x-lasso-profile", profile)
      |> Plug.Conn.put_resp_header("x-lasso-balance-warning", "true")
    else
      profile = conn.assigns[:profile_slug]

      if profile do
        Plug.Conn.put_resp_header(conn, "x-lasso-profile", profile)
      else
        conn
      end
    end
  end
end
