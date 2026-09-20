defmodule Lasso.Providers.ChainIdentityTest do
  use ExUnit.Case, async: false

  alias Lasso.Providers.{Catalog, ChainIdentity, InstanceState}

  setup do
    id = "identity-#{System.unique_integer([:positive])}"
    snapshot = Catalog.snapshot()
    on_exit(fn -> InstanceState.clear(id) end)
    %{id: id, snapshot: snapshot}
  end

  test "unknown identity admits both transports", %{id: id, snapshot: snapshot} do
    assert ChainIdentity.check(id, :http, snapshot.generation) == :ok
    assert ChainIdentity.check(id, :ws, snapshot.generation) == :ok
  end

  test "rejection is isolated by instance, generation and transport", %{
    id: id,
    snapshot: snapshot
  } do
    ChainIdentity.record(ChainIdentity.capture(id, snapshot), :rejected)

    assert ChainIdentity.check(id, :http, snapshot.generation) ==
             {:error, :chain_identity_rejected}

    assert ChainIdentity.check(id, :ws, snapshot.generation) == :ok
    assert ChainIdentity.check(id <> "other", :http, snapshot.generation) == :ok
    assert ChainIdentity.check(id, :http, snapshot.generation + 1) == :ok
  end

  test "only a later matching observation clears rejection", %{id: id, snapshot: snapshot} do
    old = ChainIdentity.capture(id, snapshot)
    rejection = ChainIdentity.capture(id, snapshot)
    recovery = ChainIdentity.capture(id, snapshot)
    ChainIdentity.record(rejection, :rejected)
    ChainIdentity.record(old, :verified)

    assert ChainIdentity.check(id, :http, snapshot.generation) ==
             {:error, :chain_identity_rejected}

    ChainIdentity.record(recovery, :verified)
    assert ChainIdentity.check(id, :http, snapshot.generation) == :ok
    ChainIdentity.record(rejection, :rejected)
    assert ChainIdentity.check(id, :http, snapshot.generation) == :ok
  end

  test "observations from a non-current generation cannot clear rejection", %{
    id: id,
    snapshot: snapshot
  } do
    ChainIdentity.record(ChainIdentity.capture(id, snapshot), :rejected)
    stale = ChainIdentity.capture(id, %{snapshot | generation: snapshot.generation + 1})
    ChainIdentity.record(stale, :verified)

    assert ChainIdentity.check(id, :http, snapshot.generation) ==
             {:error, :chain_identity_rejected}
  end

  test "instance teardown clears the observation", %{id: id, snapshot: snapshot} do
    ChainIdentity.record(ChainIdentity.capture(id, snapshot), :rejected)
    InstanceState.clear(id)
    assert ChainIdentity.check(id, :http, snapshot.generation) == :ok
  end
end
