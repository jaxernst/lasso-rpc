defmodule Lasso.Testing.MockHTTPProviderLifecycleTest do
  use ExUnit.Case, async: false

  alias Lasso.Config.ConfigStore
  alias Lasso.Providers.{Catalog, ProbeCoordinator}
  alias Lasso.RPC.TransportRegistry
  alias Lasso.Testing.MockHTTPProvider

  @moduletag :integration

  test "startup is ready synchronously and teardown removes every routing surface" do
    chain_id = unique_chain_id()
    provider_id = "lifecycle-provider"

    assert {:ok, ^provider_id} = start_mock("public", chain_id, provider_id)
    assert_provider_ready("public", chain_id, provider_id)

    assert :ok = MockHTTPProvider.stop_mock("public", chain_id, provider_id)
    refute_provider_present("public", chain_id, provider_id)

    assert {:ok, ^provider_id} = start_mock("public", chain_id, provider_id)
    assert_provider_ready("public", chain_id, provider_id)

    assert :ok = MockHTTPProvider.stop_mock("public", chain_id, provider_id)
    refute_provider_present("public", chain_id, provider_id)

    stop_chain("public", chain_id)
  end

  test "teardown uses the profile that owns the provider" do
    profile = "fixture-profile-#{System.unique_integer([:positive])}"
    chain_id = unique_chain_id()
    provider_id = "profile-provider"

    assert {:ok, ^provider_id} = start_mock(profile, chain_id, provider_id)
    assert_provider_ready(profile, chain_id, provider_id)

    assert :ok = MockHTTPProvider.stop_mock(profile, chain_id, provider_id)
    refute_provider_present(profile, chain_id, provider_id)

    stop_chain(profile, chain_id)
  end

  test "probe coordinator does not probe behavior-backed mock endpoints" do
    chain_id = unique_chain_id()
    provider_id = "probe-isolated-provider"

    assert {:ok, ^provider_id} = start_mock("public", chain_id, provider_id)
    instance_id = Catalog.lookup_instance_id("public", chain_id, provider_id)

    assert {:ok, %{mock?: true}} = Catalog.get_instance(instance_id)

    probe_pid = start_supervised!({ProbeCoordinator, chain_id})
    ProbeCoordinator.reload_instances(chain_id)
    Process.sleep(25)
    send(probe_pid, :tick)
    Process.sleep(25)

    state = :sys.get_state(ProbeCoordinator.via_name(chain_id))
    assert state.instances[instance_id].last_probe_monotonic == nil

    assert :ok = MockHTTPProvider.stop_mock("public", chain_id, provider_id)
    stop_chain("public", chain_id)
  end

  defp start_mock(profile, chain_id, provider_id) do
    MockHTTPProvider.start_mock(chain_id, %{
      id: provider_id,
      profile: profile,
      behavior: :healthy,
      priority: 1
    })
  end

  defp assert_provider_ready(profile, chain_id, provider_id) do
    assert {:ok, _provider} = ConfigStore.get_provider(profile, chain_id, provider_id)
    assert is_binary(Catalog.lookup_instance_id(profile, chain_id, provider_id))
    assert {:ok, _channel} = TransportRegistry.get_channel(profile, chain_id, provider_id, :http)
    assert [{pid, _}] = Registry.lookup(Lasso.Registry, {:http_provider, provider_id})
    assert Process.alive?(pid)
  end

  defp refute_provider_present(profile, chain_id, provider_id) do
    assert {:error, :not_found} = ConfigStore.get_provider(profile, chain_id, provider_id)
    assert Catalog.lookup_instance_id(profile, chain_id, provider_id) == nil

    assert {:error, _reason} =
             TransportRegistry.get_channel(profile, chain_id, provider_id, :http)

    assert Registry.lookup(Lasso.Registry, {:http_provider, provider_id}) == []
    assert GenServer.whereis(ProbeCoordinator.via_name(chain_id)) == nil
  end

  defp stop_chain(profile, chain_id) do
    Lasso.ProfileChainSupervisor.stop_profile_chain(profile, chain_id)
    ConfigStore.unregister_chain_runtime(profile, chain_id)
  end

  defp unique_chain_id do
    800_000_000 + rem(System.unique_integer([:positive]), 100_000_000)
  end
end
