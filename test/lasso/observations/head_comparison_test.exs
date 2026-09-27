defmodule Lasso.Observations.HeadComparisonTest do
  use ExUnit.Case, async: true

  alias Lasso.Observations.{HeadComparison, HeadObservation, HeadReference, HeadSnapshot}
  alias Lasso.Observations.HeadComparison.{AssessmentPolicy, Policy}

  @now 1_000_000
  @policy %Policy{
    block_time_ms: 1_000,
    reference_freshness_ms: 30_000,
    agreement_window_ms: 2_000
  }
  @assessment_policy %AssessmentPolicy{freshness_ms: 300_000, max_lag_blocks: 2}

  defp observation(instance_id, transport, height, age_ms \\ 0, attrs \\ %{}) do
    defaults = %{
      chain_id: 1,
      instance_id: instance_id,
      transport: transport,
      height: height,
      observed_at_ms: @now - age_ms
    }

    {:ok, observation} = HeadObservation.new(Map.merge(defaults, attrs))
    observation
  end

  test "two agreeing instances establish a qualified reference" do
    snapshot =
      HeadComparison.derive(
        1,
        [observation("a", :ws, 100), observation("b", :http, 100)],
        @policy,
        @now
      )

    assert snapshot.reference_height == 100
    assert snapshot.qualification == :qualified
    assert snapshot.support == 2
  end

  test "a pre-upgrade snapshot without a hash remains assessable during rolling deployment" do
    observed = observation("a", :ws, 100, 0, %{block_hash: "0xaaa"})

    snapshot =
      HeadComparison.derive(
        1,
        [observed, observation("b", :ws, 100, 0, %{block_hash: "0xaaa"})],
        @policy,
        @now
      )
      |> Map.delete(:reference_block_hash)

    assert %{status: :eligible} =
             HeadComparison.assess(snapshot, observed, @assessment_policy, @now)
  end

  test "one outlier cannot move a two-of-three reference" do
    snapshot =
      HeadComparison.derive(
        1,
        [
          observation("a", :ws, 100),
          observation("b", :http, 101),
          observation("outlier", :ws, 1_000)
        ],
        @policy,
        @now
      )

    assert snapshot.reference_height == 101
    assert snapshot.latest_observed_height == 1_000
    assert snapshot.qualification == :qualified
    assert snapshot.supporting_instances == ["a", "b"]
    assert snapshot.dissenting_instances == ["outlier"]
  end

  test "time alignment qualifies asynchronous facts without inventing a reference height" do
    snapshot =
      HeadComparison.derive(
        1,
        [observation("older", :http, 90, 10_000), observation("newer", :http, 100)],
        @policy,
        @now
      )

    assert snapshot.qualification == :qualified
    assert snapshot.reference_height == 100
    assert snapshot.reference_observed_at_ms == @now
    assert snapshot.reference_instance_id == "newer"

    old_snapshot =
      HeadComparison.derive(
        1,
        [observation("a", :http, 90, 10_000), observation("b", :http, 90, 10_000)],
        @policy,
        @now
      )

    assert old_snapshot.qualification == :qualified
    assert old_snapshot.reference_height == 90
    refute old_snapshot.reference_height == 100
  end

  test "an aligned older vote cannot make the concrete reference regress" do
    snapshot =
      HeadComparison.derive(
        1,
        [observation("older", :http, 100, 10_000), observation("newer", :http, 109)],
        @policy,
        @now
      )

    assert snapshot.qualification == :qualified
    assert snapshot.reference_height == 109
    assert snapshot.reference_instance_id == "newer"
  end

  test "qualified reference validity is bounded by supporters rather than an old dissenter" do
    snapshot =
      HeadComparison.derive(
        1,
        [
          observation("a", :ws, 100),
          observation("b", :ws, 100),
          observation("old-outlier", :ws, 1_000, 29_000)
        ],
        @policy,
        @now
      )

    assert snapshot.qualification == :qualified
    assert snapshot.supporting_instances == ["a", "b"]
    assert snapshot.valid_through_ms == @now + @policy.reference_freshness_ms
  end

  test "two divergent instances and a two-two split remain ambiguous" do
    two =
      HeadComparison.derive(
        1,
        [observation("a", :ws, 100), observation("b", :ws, 1_000)],
        @policy,
        @now
      )

    split =
      HeadComparison.derive(
        1,
        [
          observation("a", :ws, 100),
          observation("b", :ws, 101),
          observation("c", :ws, 1_000),
          observation("d", :ws, 1_001)
        ],
        @policy,
        @now
      )

    assert two.qualification == :ambiguous
    assert split.qualification == :ambiguous
  end

  test "agreement is centered on a real median observation rather than an edge" do
    snapshot =
      HeadComparison.derive(
        1,
        [
          observation("lower", :ws, 100),
          observation("middle", :ws, 102),
          observation("upper", :ws, 104)
        ],
        @policy,
        @now
      )

    assert snapshot.qualification == :qualified
    assert snapshot.support == 3
    assert snapshot.reference_height == 102
    assert snapshot.reference_instance_id == "middle"
  end

  test "one instance gets one vote even when both transports are observed" do
    snapshot =
      HeadComparison.derive(
        1,
        [
          observation("a", :http, 1_000),
          observation("a", :ws, 100, 1_000),
          observation("b", :ws, 100)
        ],
        @policy,
        @now
      )

    assert snapshot.voter_count == 2
    assert snapshot.reference_height == 100
    assert snapshot.qualification == :qualified
  end

  test "a materially newer HTTP fact replaces an old WebSocket fact for one instance" do
    snapshot =
      HeadComparison.derive(
        1,
        [
          observation("a", :ws, 90, 5_000),
          observation("a", :http, 100),
          observation("b", :http, 100)
        ],
        @policy,
        @now
      )

    assert snapshot.qualification == :qualified
    assert snapshot.reference_height == 100
    assert snapshot.supporting_instances == ["a", "b"]
  end

  test "stale numeric outliers do not become the latest current observation" do
    snapshot =
      HeadComparison.derive(
        1,
        [
          observation("stale-outlier", :ws, 10_000, 31_000),
          observation("a", :ws, 100),
          observation("b", :ws, 100)
        ],
        @policy,
        @now
      )

    assert snapshot.latest_observed_height == 100
    assert snapshot.latest_observed_at_ms == @now
  end

  test "low-frequency observations remain assessable without voting on the reference" do
    archive =
      observation("archive", :http, 90, 120_000, %{
        poll_references: [
          %HeadReference{
            chain_id: 1,
            height: 100,
            revision: 1,
            captured_at_ms: @now - 120_000,
            instance_id: "a"
          }
        ]
      })

    snapshot =
      HeadComparison.derive(
        1,
        [archive, observation("a", :ws, 100), observation("b", :ws, 100)],
        @policy,
        @now
      )

    assert snapshot.voter_count == 2

    assert %{status: :lagging, lag: -10} =
             HeadComparison.assess(
               snapshot,
               archive,
               @assessment_policy,
               @now
             )
  end

  test "lag assessment is transport-specific" do
    http =
      observation("a", :http, 90, 0, %{
        poll_references: [
          %HeadReference{
            chain_id: 1,
            height: 100,
            revision: 1,
            captured_at_ms: @now,
            instance_id: "a"
          }
        ]
      })

    ws = observation("a", :ws, 100)

    snapshot =
      HeadComparison.derive(
        1,
        [http, ws, observation("b", :ws, 100)],
        @policy,
        @now
      )

    assert %{status: :lagging, lag: -10} =
             HeadComparison.assess(snapshot, http, @assessment_policy, @now)

    assert %{status: :eligible, lag: 0} =
             HeadComparison.assess(snapshot, ws, @assessment_policy, @now)
  end

  test "HTTP without a captured qualified reference remains unknown" do
    http = observation("a", :http, 90)

    snapshot =
      HeadComparison.derive(
        1,
        [http, observation("b", :ws, 100), observation("c", :ws, 100)],
        @policy,
        @now
      )

    assert %{status: :unknown, reason: :poll_reference_missing} =
             HeadComparison.assess(snapshot, http, @assessment_policy, @now)
  end

  test "a qualified poll reference preserves lag without influencing derivation" do
    poll_reference = %HeadReference{
      chain_id: 1,
      height: 100,
      revision: 1,
      captured_at_ms: @now - 10_000,
      instance_id: "a"
    }

    http =
      observation("archive", :http, 98, 10_000, %{
        poll_references: [poll_reference],
        sample_interval_ms: 300_000
      })

    snapshot =
      HeadComparison.derive(
        1,
        [http, observation("a", :ws, 110), observation("b", :ws, 110)],
        @policy,
        @now
      )

    assert snapshot.reference_height == 110

    assert %{status: :eligible, lag: -2} =
             HeadComparison.assess(snapshot, http, @assessment_policy, @now)
  end

  test "a poll reference from another comparison scope cannot exclude a route" do
    http =
      observation("a", :http, 90, 0, %{
        poll_references: [
          %HeadReference{
            chain_id: 1,
            height: 1_000,
            revision: 1,
            captured_at_ms: @now,
            instance_id: "outside-profile",
            scope_id: {:head_scope, :outside}
          }
        ]
      })

    snapshot =
      HeadComparison.derive(
        1,
        [http, observation("b", :ws, 100), observation("c", :ws, 100)],
        @policy,
        @now,
        1,
        {:head_scope, :current}
      )

    assert %{status: :unknown, reason: :poll_reference_scope_mismatch} =
             HeadComparison.assess(snapshot, http, @assessment_policy, @now)
  end

  test "one shared HTTP fact retains independent baselines for every profile scope" do
    public_scope = {:head_scope, :public}
    premium_scope = {:head_scope, :premium}

    http =
      observation("shared", :http, 98, 0, %{
        poll_references: [
          %HeadReference{
            chain_id: 1,
            height: 100,
            revision: 4,
            captured_at_ms: @now,
            scope_id: public_scope
          },
          %HeadReference{
            chain_id: 1,
            height: 105,
            revision: 9,
            captured_at_ms: @now,
            scope_id: premium_scope
          }
        ]
      })

    public_snapshot =
      HeadComparison.derive(
        1,
        [http, observation("public-a", :ws, 110), observation("public-b", :ws, 110)],
        @policy,
        @now,
        5,
        public_scope
      )

    premium_snapshot =
      HeadComparison.derive(
        1,
        [http, observation("premium-a", :ws, 115), observation("premium-b", :ws, 115)],
        @policy,
        @now,
        10,
        premium_scope
      )

    assert %{status: :eligible, lag: -2} =
             HeadComparison.assess(public_snapshot, http, @assessment_policy, @now)

    assert %{status: :lagging, lag: -7} =
             HeadComparison.assess(premium_snapshot, http, @assessment_policy, @now)
  end

  test "an expired snapshot cannot produce a lag verdict" do
    observation = observation("a", :ws, 100)

    snapshot =
      1
      |> HeadComparison.derive(
        [observation, observation("b", :ws, 100)],
        @policy,
        @now - 31_000
      )
      |> Map.put(:valid_through_ms, @now - 1)

    assert %{status: :unknown, reason: :reference_stale} =
             HeadComparison.assess(snapshot, observation, @assessment_policy, @now)
  end

  test "unqualified reference evidence cannot classify a provider as lagging" do
    observation = observation("only", :ws, 100)
    snapshot = HeadComparison.derive(1, [observation], @policy, @now)

    assert %{status: :unknown, reason: :reference_unqualified} =
             HeadComparison.assess(
               snapshot,
               observation,
               @assessment_policy,
               @now
             )
  end

  test "an observation cannot be assessed against another chain" do
    observed = observation("a", :ws, 100)

    snapshot =
      HeadComparison.derive(
        1,
        [observed, observation("b", :ws, 100)],
        @policy,
        @now
      )

    assert %{status: :unknown, reason: :chain_mismatch} =
             HeadComparison.assess(%{snapshot | chain_id: 2}, observed, @assessment_policy, @now)
  end

  test "only qualified snapshots produce poll references" do
    qualified =
      HeadComparison.derive(
        1,
        [observation("a", :ws, 100), observation("b", :ws, 100)],
        @policy,
        @now,
        4
      )

    unqualified = HeadComparison.derive(1, [observation("a", :ws, 100)], @policy, @now)

    assert {:ok, %HeadReference{height: 100, revision: 4}} = HeadSnapshot.reference(qualified)
    assert {:error, :unqualified} = HeadSnapshot.reference(unqualified)
  end
end
