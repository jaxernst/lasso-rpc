defmodule Lasso.Test.Harness.Tenant do
  @moduledoc "File-backed adapter for an owned harness profile."
  import ExUnit.Assertions
  alias Lasso.Test.Harness.{Rpc, Settle}
  def isolate!, do: :ok

  def open!(providers) do
    slug = "harness-#{System.unique_integer([:positive])}"
    file = Path.join(System.fetch_env!("LASSO_PROFILES_DIR"), slug <> ".yml")

    config = %{
      "chains" => %{
        "anvil" => %{
          "chain_id" => 31_337,
          "head_policy" => "off",
          "providers" =>
            Enum.with_index(providers, 1)
            |> Enum.map(fn {f, priority} ->
              %{
                "id" => f.name,
                "name" => f.name,
                "url" => f.url,
                "priority" => priority,
                "subscribe_new_heads" => false,
                "background_observations" => false
              }
            end)
        }
      }
    }

    File.write!(
      file,
      "---\nname: Harness\nslug: #{slug}\n---\n" <> Jason.encode!(config)
    )

    try do
      assert :ok = Lasso.Diagnostics.reload_profiles()
      origin = "http://127.0.0.1:#{System.fetch_env!("PORT")}"

      tenant = %{
        file: file,
        profile: slug,
        rpc_url: "#{origin}/rpc/profile/#{slug}/priority/31337"
      }

      Settle.await("Core ready", fn ->
        case Finch.build(:get, "#{origin}/api/ready") |> Finch.request(Lasso.Finch) do
          {:ok, %{status: 200}} -> {:ok, :ready}
          other -> other
        end
      end)

      Settle.await("Core tenant credential HTTP route", fn ->
        case Rpc.call(tenant, "eth_chainId") do
          %{body: %{"result" => "0x7a69"}} -> {:ok, :routed}
          other -> other
        end
      end)

      tenant
    rescue
      error ->
        File.rm!(file)
        assert {:ok, _} = Lasso.Diagnostics.retire_tenant(slug)
        reraise error, __STACKTRACE__
    end
  end

  def credentials(t), do: %{rpc_url: t.rpc_url}

  def close!(t) do
    marker = Settle.listen([:lasso, :tenant, :retired])

    try do
      File.rm!(t.file)
      assert {:ok, receipt} = Lasso.Diagnostics.retire_tenant(t.profile)

      Settle.event(
        marker,
        &(&1.profile == t.profile and &1.node == node() and &1.generation == receipt.generation and
            &1.operation == receipt.operation and &1.outcome == :ok)
      )

      :ok
    after
      Settle.unlisten(marker)
    end
  end
end
