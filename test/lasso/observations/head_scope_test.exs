defmodule Lasso.Observations.HeadScopeTest do
  use ExUnit.Case, async: true

  alias Lasso.Observations.{HeadComparison, HeadScope}

  @policy %HeadComparison.Policy{
    block_time_ms: 1_000,
    reference_freshness_ms: 30_000,
    agreement_window_ms: 2_000
  }

  test "scope identity is independent of provider ordering and duplicates" do
    left = HeadScope.new("public", 1, ["b", "a", "a"], @policy)
    right = HeadScope.new("public", 1, ["a", "b"], @policy)

    assert left.instance_ids == ["a", "b"]
    assert left.scope_id == right.scope_id
    assert left.cache_key == right.cache_key
  end

  test "comparison policy is part of scope identity" do
    left = HeadScope.new("public", 1, ["a", "b"], @policy)
    right = HeadScope.new("public", 1, ["a", "b"], %{@policy | agreement_window_ms: 3_000})

    refute left.scope_id == right.scope_id
    refute left.cache_key == right.cache_key
  end

  test "identical upstreams in different profiles have distinct scope identities" do
    public = HeadScope.new("public", 1, ["shared"], @policy)
    private = HeadScope.new("private", 1, ["shared"], @policy)

    refute public.scope_id == private.scope_id
    refute public.cache_key == private.cache_key
  end

  test "scoped comparison excludes unrelated physical upstreams" do
    scope = HeadScope.new("private", 1, ["a", "b"], @policy)

    observations =
      for {instance_id, height} <- [{"a", 100}, {"b", 100}, {"other", 200}] do
        {:ok, observation} =
          Lasso.Observations.HeadObservation.http(%{
            chain_id: 1,
            instance_id: instance_id,
            height: height,
            observed_at_ms: 1_000
          })

        observation
      end

    snapshot = HeadComparison.derive(scope, observations, 1_000, 1)

    assert snapshot.scope_id == scope.scope_id
    assert snapshot.reference_height == 100
    assert snapshot.qualification == :qualified
    assert snapshot.voter_count == 2
  end
end
