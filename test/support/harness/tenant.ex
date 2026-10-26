defmodule Lasso.Test.Harness.Tenant do
  @moduledoc "File-backed adapter for an owned harness profile."
  import ExUnit.Assertions
  alias Lasso.Test.Harness.{Rpc, Settle}

  def open!(providers) do
    slug = "harness-#{System.unique_integer([:positive])}"
    file = Path.join(System.fetch_env!("LASSO_PROFILES_DIR"), slug <> ".yml")

    config = configuration(providers, [])

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

  @doc "Publishes an owned file-profile replacement and joins its reload."
  def replace!(tenant, providers, opts \\ []) do
    write_replacement!(tenant, providers, opts)
    assert :ok = Lasso.Diagnostics.reload_profiles()
    tenant
  end

  @doc "Rejects an invalid owned file replacement while its live configuration keeps serving."
  def reject_replace!(tenant, providers, opts) do
    write_replacement!(tenant, providers, opts)
    assert {:error, _reason} = Lasso.Diagnostics.reload_profiles()
    tenant
  end

  @doc "Returns the owned provider's operator knowledge report in the shared report shape."
  def knowledge!(tenant, fleet) do
    {:ok, hints} = Lasso.Diagnostics.provider_knowledge(tenant.profile, 31_337, fleet.name)

    for hint <- Map.get(hints, :http, []) do
      %{
        "kind" => to_string(hint.kind),
        "source" => if(hint.source == :local, do: "learned", else: to_string(hint.source)),
        "value" => Map.get(hint, :value),
        "transport" => "http"
      }
    end
  end

  defp write_replacement!(tenant, providers, opts) do
    [metadata, _document] = tenant.file |> File.read!() |> String.split("\n---\n", parts: 2)

    File.write!(
      tenant.file,
      metadata <> "\n---\n" <> Jason.encode!(configuration(providers, opts))
    )
  end

  defp configuration(providers, opts) do
    overrides = Keyword.get(opts, :providers, %{})

    %{
      "chains" => %{
        "anvil" => %{
          "chain_id" => 31_337,
          "head_policy" => "off",
          "providers" =>
            Enum.with_index(providers, 1)
            |> Enum.map(fn {fleet, priority} ->
              fields = Map.get(overrides, fleet.name, %{})
              limits = Map.get(fields, "limits", %{})

              capabilities =
                Map.get(fields, "capabilities", %{})
                |> declare_span(limits["logs_span"])
                |> declare_methods(limits["methods_blocked"])

              %{
                "priority" => priority,
                "subscribe_new_heads" => false,
                "background_observations" => false
              }
              |> Map.merge(Map.drop(fields, ["heads", "limits", "capabilities"]))
              |> Map.merge(%{
                "id" => fleet.name,
                "name" => fleet.name,
                "url" => fleet.url,
                "capabilities" => capabilities
              })
            end)
        }
      }
    }
  end

  defp declare_span(capabilities, nil), do: capabilities

  defp declare_span(capabilities, span),
    do:
      Map.update(
        capabilities,
        "limits",
        %{"max_block_range" => span},
        &Map.put(&1, "max_block_range", span)
      )

  defp declare_methods(capabilities, nil), do: capabilities

  defp declare_methods(capabilities, methods),
    do: Map.put(capabilities, "unsupported_methods", methods)

  @doc "Serving owners whose identities must survive an injected fault in this adapter."
  def serving_owners do
    Map.new(
      [LassoWeb.Endpoint, Lasso.Providers.Catalog.Owner, Lasso.Config.ConfigStore],
      &{&1, Process.whereis(&1)}
    )
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
