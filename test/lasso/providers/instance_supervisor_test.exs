defmodule Lasso.Providers.InstanceSupervisorTest do
  use ExUnit.Case, async: false

  alias Lasso.Config.ConfigStore
  alias Lasso.Providers.{Catalog, InstanceSupervisor}

  @profile "is_test"
  @chain "is_test_chain"
  @config_table :lasso_config_store

  setup do
    original_profiles = ConfigStore.list_profiles()

    on_exit(fn ->
      ConfigStore.unregister_chain_runtime(@profile, @chain)
      :ets.insert(@config_table, {{:profile_list}, original_profiles})
      Catalog.build_from_config()
    end)

    :ok
  end

  describe "start_link/1 with HTTP-only provider" do
    setup do
      register_chain(@profile, @chain, [
        %{id: "http_only", name: "HTTP Only", url: "https://is-test.example.com", priority: 1}
      ])

      Catalog.build_from_config()
      instance_id = Catalog.lookup_instance_id(@profile, @chain, "http_only")

      on_exit(fn ->
        stop_instance_supervisor(instance_id)
      end)

      %{instance_id: instance_id}
    end

    test "starts with HTTP circuit breaker only", %{instance_id: instance_id} do
      {:ok, pid} = InstanceSupervisor.start_link(instance_id)
      assert Process.alive?(pid)

      children = Supervisor.which_children(pid)
      child_ids = Enum.map(children, fn {id, _, _, _} -> id end)

      assert {:circuit, :http} in child_ids
      refute {:circuit, :ws} in child_ids

      refute Enum.any?(child_ids, fn
               {:ws_connection, _} -> true
               _ -> false
             end)
    end
  end

  describe "start_link/1 with HTTP+WS provider" do
    setup do
      register_chain(@profile, @chain, [
        %{
          id: "http_ws",
          name: "HTTP+WS",
          url: "https://is-test-ws.example.com",
          ws_url: "wss://is-test-ws.example.com/ws",
          priority: 1
        }
      ])

      Catalog.build_from_config()
      instance_id = Catalog.lookup_instance_id(@profile, @chain, "http_ws")

      on_exit(fn ->
        stop_instance_supervisor(instance_id)
      end)

      %{instance_id: instance_id}
    end

    test "starts with HTTP CB, WS CB, and WS connection", %{instance_id: instance_id} do
      {:ok, pid} = InstanceSupervisor.start_link(instance_id)
      assert Process.alive?(pid)

      children = Supervisor.which_children(pid)
      child_ids = Enum.map(children, fn {id, _, _, _} -> id end)

      assert {:circuit, :http} in child_ids
      assert {:circuit, :ws} in child_ids
    end
  end

  describe "start_link/1 with unknown instance_id" do
    test "returns :ignore when instance not in catalog" do
      assert :ignore = InstanceSupervisor.start_link("unknown:fake:000000000000")
    end
  end

  describe "via_name/1" do
    test "returns a Registry via tuple" do
      {:via, Registry, {Lasso.Registry, key}} = InstanceSupervisor.via_name("test:id:abc123")
      assert key == {:instance_supervisor, "test:id:abc123"}
    end
  end

  describe "Registry registration" do
    setup do
      register_chain(@profile, @chain, [
        %{id: "reg_test", name: "Reg", url: "https://is-test-reg.example.com", priority: 1}
      ])

      Catalog.build_from_config()
      instance_id = Catalog.lookup_instance_id(@profile, @chain, "reg_test")

      on_exit(fn ->
        stop_instance_supervisor(instance_id)
      end)

      %{instance_id: instance_id}
    end

    test "registers via Registry on start", %{instance_id: instance_id} do
      {:ok, pid} = InstanceSupervisor.start_link(instance_id)
      assert GenServer.whereis(InstanceSupervisor.via_name(instance_id)) == pid
    end

    test "returns error if already started", %{instance_id: instance_id} do
      {:ok, _pid} = InstanceSupervisor.start_link(instance_id)
      assert {:error, {:already_started, _}} = InstanceSupervisor.start_link(instance_id)
    end
  end

  # Helpers

  defp register_chain(profile, chain, providers) do
    current = ConfigStore.list_profiles()

    unless profile in current do
      :ets.insert(@config_table, {{:profile_list}, [profile | current]})
    end

    ConfigStore.register_chain_runtime(profile, chain, %{
      chain_id: 99,
      name: chain,
      providers: providers
    })
  end

  defp stop_instance_supervisor(instance_id) do
    case GenServer.whereis(InstanceSupervisor.via_name(instance_id)) do
      nil -> :ok
      pid -> Supervisor.stop(pid, :normal, 1_000)
    end
  catch
    :exit, _ -> :ok
  end
end
