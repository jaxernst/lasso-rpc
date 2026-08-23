defmodule Lasso.Core.Streaming.ClientSubscriptionRegistryTest do
  use ExUnit.Case, async: false

  alias Lasso.Core.Streaming.{ClientSubscriptionRegistry, UpstreamSubscriptionPool}

  @profile "test-client-registry"
  @chain_id 42_424
  @key {:newHeads}

  test "client DOWN decrements the upstream pool refcount" do
    profile = "#{@profile}-#{System.unique_integer([:positive])}"

    {:ok, pool} = UpstreamSubscriptionPool.start_link({profile, @chain_id})
    {:ok, registry} = ClientSubscriptionRegistry.start_link({profile, @chain_id})

    :sys.replace_state(pool, fn state ->
      %{
        state
        | keys: %{
            @key => %{
              refcount: 2,
              status: :active,
              primary_provider_id: "provider-a",
              instance_id: "instance-a",
              markers: %{},
              dedupe: nil,
              noproc_retries: 0
            }
          }
      }
    end)

    client = spawn(fn -> Process.sleep(:infinity) end)
    :ok = ClientSubscriptionRegistry.add_client(profile, @chain_id, "sub-1", client, @key)

    Process.exit(client, :kill)

    assert_eventually(fn ->
      [] == ClientSubscriptionRegistry.list_by_key(profile, @chain_id, @key)
    end)

    assert_eventually(fn ->
      %{keys: %{@key => %{refcount: 1}}} = :sys.get_state(pool)
      true
    end)

    GenServer.stop(registry)
    GenServer.stop(pool)
  end

  test "continuity exhaustion is delivered to every downstream subscriber" do
    profile = "#{@profile}-termination-#{System.unique_integer([:positive])}"
    {:ok, registry} = ClientSubscriptionRegistry.start_link({profile, @chain_id})

    :ok = ClientSubscriptionRegistry.add_client(profile, @chain_id, "sub-1", self(), @key)
    :ok = ClientSubscriptionRegistry.add_client(profile, @chain_id, "sub-2", self(), @key)

    :ok = ClientSubscriptionRegistry.terminate(profile, @chain_id, @key, :continuity_exhausted)

    assert_receive {:subscription_terminated, "sub-1", :continuity_exhausted}
    assert_receive {:subscription_terminated, "sub-2", :continuity_exhausted}

    GenServer.stop(registry)
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(fun, 0), do: assert(fun.())
end
