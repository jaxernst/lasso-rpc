defmodule Lasso.Providers.ChainIdentityTest do
  use ExUnit.Case, async: false

  alias Lasso.Providers.{Catalog, ChainIdentity, InstanceState}

  setup do
    id = "identity-#{System.unique_integer([:positive])}"
    Catalog.build_from_config()
    snapshot = Catalog.snapshot()
    on_exit(fn -> InstanceState.clear(id) end)
    %{id: id, snapshot: snapshot}
  end

  test "unknown identity admits both transports", %{id: id} do
    assert ChainIdentity.check(id, :http) == :ok
    assert ChainIdentity.check(id, :ws) == :ok
  end

  test "rejection is isolated by instance and transport", %{
    id: id,
    snapshot: snapshot
  } do
    ChainIdentity.record(ChainIdentity.capture(id, snapshot), :rejected)

    assert ChainIdentity.check(id, :http) ==
             {:error, :chain_identity_rejected}

    assert ChainIdentity.check(id, :ws) == :ok
    assert ChainIdentity.check(id <> "other", :http) == :ok
  end

  test "only a later matching observation clears rejection", %{id: id, snapshot: snapshot} do
    old = ChainIdentity.capture(id, snapshot)
    rejection = ChainIdentity.capture(id, snapshot)
    recovery = ChainIdentity.capture(id, snapshot)
    ChainIdentity.record(rejection, :rejected)
    ChainIdentity.record(old, :verified)

    assert ChainIdentity.check(id, :http) ==
             {:error, :chain_identity_rejected}

    ChainIdentity.record(recovery, :verified)
    assert ChainIdentity.check(id, :http) == :ok
    ChainIdentity.record(rejection, :rejected)
    assert ChainIdentity.check(id, :http) == :ok
  end

  test "observations from a non-current generation cannot clear rejection", %{
    id: id,
    snapshot: snapshot
  } do
    ChainIdentity.record(ChainIdentity.capture(id, snapshot), :rejected)
    stale = ChainIdentity.capture(id, %{snapshot | generation: snapshot.generation + 1})
    ChainIdentity.record(stale, :verified)

    assert ChainIdentity.check(id, :http) ==
             {:error, :chain_identity_rejected}
  end

  test "instance teardown clears the observation", %{id: id, snapshot: snapshot} do
    ChainIdentity.record(ChainIdentity.capture(id, snapshot), :rejected)
    InstanceState.clear(id)
    assert ChainIdentity.check(id, :http) == :ok
  end
end
