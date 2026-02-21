defmodule Lasso.RPC.ProviderPoolProbeHealthTest do
  use ExUnit.Case, async: false
  import Mox

  alias Lasso.RPC.ProviderPool
  alias Lasso.Config.ChainConfig

  setup_all do
    TestHelper.ensure_test_environment_ready()
    :ok
  end

  setup :verify_on_exit!

  setup do
    stub(Lasso.RPC.HttpClientMock, :request, fn _endpoint, method, _params, _timeout ->
      case method do
        "eth_chainId" -> {:ok, "0x1"}
        _ -> {:error, :method_not_mocked}
      end
    end)

    :ok
  end

  defp provider_struct(attrs) do
    struct(
      ChainConfig.Provider,
      Map.merge(
        %{
          id: "test_provider",
          name: "Test Provider",
          priority: 1,
          url: "http://example",
          ws_url: nil
        },
        attrs
      )
    )
  end

  defp base_chain_config(providers) do
    %{
      aggregation: %{max_providers: 5},
      global: %{
        health_check: %{
          interval: 2000,
          timeout: 5_000,
          failure_threshold: 2,
          recovery_threshold: 1
        },
        provider_management: %{load_balancing: "priority"}
      },
      providers: providers
    }
  end

  describe "update_probe_health/5" do
    test "probe success transitions :connecting to :healthy" do
      p = provider_struct(%{id: "probe_success_1", name: "P1"})
      chain_config = base_chain_config([p])
      chain = "probe_health_test_1"

      {:ok, _pid} = ProviderPool.start_link({"default", chain, chain_config})
      :ok = ProviderPool.register_provider("default", chain, p.id, p)

      # Verify initial state is :connecting
      {:ok, status} = ProviderPool.get_status("default", chain)
      provider = Enum.find(status.providers, &(&1.id == p.id))
      assert provider.http_status == :connecting

      # Send probe success
      ProviderPool.update_probe_health("default", chain, p.id, :http, :success)
      Process.sleep(50)

      # Should transition to :healthy
      {:ok, status} = ProviderPool.get_status("default", chain)
      provider = Enum.find(status.providers, &(&1.id == p.id))
      assert provider.http_status == :healthy
    end

    test "probe failure transitions :connecting to :degraded" do
      p = provider_struct(%{id: "probe_fail_1", name: "P1"})
      chain_config = base_chain_config([p])
      chain = "probe_health_test_2"

      {:ok, _pid} = ProviderPool.start_link({"default", chain, chain_config})
      :ok = ProviderPool.register_provider("default", chain, p.id, p)

      # Send probe failure
      ProviderPool.update_probe_health("default", chain, p.id, :http, {:failure, :timeout})
      Process.sleep(50)

      {:ok, status} = ProviderPool.get_status("default", chain)
      provider = Enum.find(status.providers, &(&1.id == p.id))
      assert provider.http_status in [:degraded, :unhealthy]
    end

    test "probe success does not override live-traffic :healthy status" do
      p = provider_struct(%{id: "probe_noop_1", name: "P1"})
      chain_config = base_chain_config([p])
      chain = "probe_health_test_3"

      {:ok, _pid} = ProviderPool.start_link({"default", chain, chain_config})
      :ok = ProviderPool.register_provider("default", chain, p.id, p)

      # Transition to healthy via live traffic success
      ProviderPool.report_success("default", chain, p.id, :http)
      Process.sleep(50)

      {:ok, status} = ProviderPool.get_status("default", chain)
      provider = Enum.find(status.providers, &(&1.id == p.id))
      assert provider.http_status == :healthy
      old_check = provider.last_health_check

      # Probe success should only update last_health_check, not change status
      Process.sleep(10)
      ProviderPool.update_probe_health("default", chain, p.id, :http, :success)
      Process.sleep(50)

      {:ok, status} = ProviderPool.get_status("default", chain)
      provider = Enum.find(status.providers, &(&1.id == p.id))
      assert provider.http_status == :healthy
      assert provider.last_health_check >= old_check
    end

    test "probe failure does not override live-traffic :degraded status" do
      p = provider_struct(%{id: "probe_noop_2", name: "P1"})
      chain_config = base_chain_config([p])
      chain = "probe_health_test_4"

      {:ok, _pid} = ProviderPool.start_link({"default", chain, chain_config})
      :ok = ProviderPool.register_provider("default", chain, p.id, p)

      # Transition to degraded via live traffic failure
      ProviderPool.report_failure("default", chain, p.id, {:network_error, "timeout"}, :http)
      Process.sleep(50)

      {:ok, status} = ProviderPool.get_status("default", chain)
      provider = Enum.find(status.providers, &(&1.id == p.id))
      assert provider.http_status in [:degraded, :unhealthy]
      old_status = provider.http_status

      # Probe failure should not change existing live-traffic-derived status
      ProviderPool.update_probe_health("default", chain, p.id, :http, {:failure, :timeout})
      Process.sleep(50)

      {:ok, status} = ProviderPool.get_status("default", chain)
      provider = Enum.find(status.providers, &(&1.id == p.id))
      assert provider.http_status == old_status
    end

    test "probe success recovers :unhealthy to :degraded (graduated step)" do
      p = provider_struct(%{id: "probe_grad_1", name: "P1"})
      chain_config = base_chain_config([p])
      chain = "probe_health_test_grad_1"

      {:ok, _pid} = ProviderPool.start_link({"default", chain, chain_config})
      :ok = ProviderPool.register_provider("default", chain, p.id, p)

      # First get to :healthy via probe
      ProviderPool.update_probe_health("default", chain, p.id, :http, :success)
      Process.sleep(50)

      # Drive to :unhealthy via live traffic failures (threshold is 3)
      for _ <- 1..3 do
        ProviderPool.report_failure("default", chain, p.id, {:network_error, "timeout"}, :http)
        Process.sleep(20)
      end

      {:ok, status} = ProviderPool.get_status("default", chain)
      provider = Enum.find(status.providers, &(&1.id == p.id))
      assert provider.http_status == :unhealthy

      # Probe success should graduate :unhealthy → :degraded (not straight to :healthy)
      ProviderPool.update_probe_health("default", chain, p.id, :http, :success)
      Process.sleep(50)

      {:ok, status} = ProviderPool.get_status("default", chain)
      provider = Enum.find(status.providers, &(&1.id == p.id))
      assert provider.http_status == :degraded
    end

    test "second probe success completes recovery :degraded to :healthy" do
      p = provider_struct(%{id: "probe_grad_2", name: "P1"})
      chain_config = base_chain_config([p])
      chain = "probe_health_test_grad_2"

      {:ok, _pid} = ProviderPool.start_link({"default", chain, chain_config})
      :ok = ProviderPool.register_provider("default", chain, p.id, p)

      # Get to :healthy via probe
      ProviderPool.update_probe_health("default", chain, p.id, :http, :success)
      Process.sleep(50)

      # Drive to :unhealthy via live traffic failures
      for _ <- 1..3 do
        ProviderPool.report_failure("default", chain, p.id, {:network_error, "timeout"}, :http)
        Process.sleep(20)
      end

      {:ok, status} = ProviderPool.get_status("default", chain)
      provider = Enum.find(status.providers, &(&1.id == p.id))
      assert provider.http_status == :unhealthy

      # First probe: :unhealthy → :degraded
      ProviderPool.update_probe_health("default", chain, p.id, :http, :success)
      Process.sleep(50)

      {:ok, status} = ProviderPool.get_status("default", chain)
      provider = Enum.find(status.providers, &(&1.id == p.id))
      assert provider.http_status == :degraded

      # Second probe: :degraded → :healthy
      ProviderPool.update_probe_health("default", chain, p.id, :http, :success)
      Process.sleep(50)

      {:ok, status} = ProviderPool.get_status("default", chain)
      provider = Enum.find(status.providers, &(&1.id == p.id))
      assert provider.http_status == :healthy
      assert provider.consecutive_failures == 0
    end

    test "probe success recovers :degraded to :healthy (single step)" do
      p = provider_struct(%{id: "probe_deg_1", name: "P1"})
      chain_config = base_chain_config([p])
      chain = "probe_health_test_deg_1"

      {:ok, _pid} = ProviderPool.start_link({"default", chain, chain_config})
      :ok = ProviderPool.register_provider("default", chain, p.id, p)

      # Get to :healthy via probe
      ProviderPool.update_probe_health("default", chain, p.id, :http, :success)
      Process.sleep(50)

      # Drive to :degraded via 1 live traffic failure
      ProviderPool.report_failure("default", chain, p.id, {:network_error, "timeout"}, :http)
      Process.sleep(50)

      {:ok, status} = ProviderPool.get_status("default", chain)
      provider = Enum.find(status.providers, &(&1.id == p.id))
      assert provider.http_status == :degraded

      # Probe success recovers :degraded → :healthy directly
      ProviderPool.update_probe_health("default", chain, p.id, :http, :success)
      Process.sleep(50)

      {:ok, status} = ProviderPool.get_status("default", chain)
      provider = Enum.find(status.providers, &(&1.id == p.id))
      assert provider.http_status == :healthy
    end

    test "probe failure from :connecting transitions to :degraded (probes resolve stuck state only)" do
      p = provider_struct(%{id: "probe_multi_fail", name: "P1"})
      chain_config = base_chain_config([p])
      chain = "probe_health_test_5"

      {:ok, _pid} = ProviderPool.start_link({"default", chain, chain_config})
      :ok = ProviderPool.register_provider("default", chain, p.id, p)

      # First failure transitions :connecting → :degraded
      ProviderPool.update_probe_health("default", chain, p.id, :http, {:failure, :timeout})
      Process.sleep(50)

      {:ok, status} = ProviderPool.get_status("default", chain)
      provider = Enum.find(status.providers, &(&1.id == p.id))
      assert provider.http_status == :degraded

      # Subsequent probe failures don't further degrade — probes only resolve :connecting,
      # live traffic drives full health lifecycle
      ProviderPool.update_probe_health("default", chain, p.id, :http, {:failure, :timeout})
      Process.sleep(50)

      {:ok, status} = ProviderPool.get_status("default", chain)
      provider = Enum.find(status.providers, &(&1.id == p.id))
      assert provider.http_status == :degraded
    end
  end
end
