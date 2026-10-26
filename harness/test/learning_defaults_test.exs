defmodule Lasso.Harness.LearningDefaultsTest do
  use ExUnit.Case, async: false
  alias Lasso.Providers.Catalog
  alias Lasso.RPC.ProviderKnowledge
  alias Lasso.RPC.ProviderKnowledge.ReadModel
  alias Lasso.RPC.TransportRegistry
  alias Lasso.Events.HeadObserved
  alias Lasso.Test.Harness.{Fleet, Rpc, Settle, Tenant}
  @moduletag :harness
  @moduletag feature: ["core-learning-defaults-1"]
  @address "0x0000000000000000000000000000000000000001"

  test "settled effects reorder by default and per-kind environment off preserves the baseline" do
    for {kind, method, params, failure} <- [
          {:method_refusal, "eth_getCode", [@address, "latest"],
           {:error, -32_601, "method not found"}},
          {:span_limit, "eth_getLogs",
           [%{"fromBlock" => "0x1", "toBlock" => "0x1f4", "address" => @address}],
           {:error, -32_600, "You can make eth_getLogs requests with up to a 10 block range"}},
          {:historical_depth, "eth_getBalance", [@address, "0x1"],
           {:error, -32_000, "missing trie node"}}
        ] do
      fleets = for name <- ["learning-primary", "learning-backup"], do: Fleet.start!(self(), name)
      [primary, backup] = fleets

      try do
        tenant = Tenant.open!(fleets)

        try do
          owners =
            Map.new(
              [Lasso.Config.ConfigStore, Lasso.Providers.Catalog.Owner, LassoWeb.Endpoint],
              &{&1, Process.whereis(&1)}
            )

          if kind == :historical_depth, do: observe_heads(tenant, fleets)
          Fleet.script(primary, method, [], failure)

          Fleet.script(
            backup,
            method,
            [],
            {:answer, if(method == "eth_getLogs", do: [], else: "0x10")}
          )

          for _ <- 1..4 do
            call(tenant, fleets, method, params, primary.name)

            settle()
          end

          {response, sends} = call(tenant, fleets, method, params)
          assert Map.has_key?(response.body, "result")
          env = "LASSO_PROVIDER_KNOWLEDGE_#{kind |> Atom.to_string() |> String.upcase()}_MODE"
          mode = System.get_env(env)
          assert mode in [nil, "on", "off"]
          expected = if mode == "off", do: [primary.name, backup.name], else: [backup.name]
          assert Enum.map(sends, & &1.fleet) == expected

          if mode != "off" do
            explanation = response.body["lasso_meta"]["learning_decision"]
            assert is_map(explanation)

            assert explanation["kind"] in [
                     "method_refusal",
                     "span_limit",
                     "historical_depth",
                     "summary"
                   ]

            assert Enum.all?(get_in(explanation, ["orders", "applied"]) || [], &is_integer/1)
            refute Map.has_key?(explanation["orders"] || %{}, "routes")
            refute Map.has_key?(explanation, "subject")
          end

          uri = URI.parse(tenant.rpc_url)

          assert {:ok, %{status: 200}} =
                   Finch.build(:get, "#{uri.scheme}://#{uri.host}:#{uri.port}/api/health")
                   |> Finch.request(Lasso.Finch)

          for {name, pid} <- owners do
            assert is_pid(pid)
            assert Process.whereis(name) == pid
          end
        after
          Tenant.close!(tenant)
        end
      after
        Enum.each(fleets, &Fleet.stop/1)
      end
    end
  end

  test "span contradictions count once while below-limit witness eviction does not count" do
    method = "eth_getLogs"
    params = [%{"fromBlock" => "0x1", "toBlock" => "0x1f4", "address" => @address}]
    larger = [%{"fromBlock" => "0x1", "toBlock" => "0x3e8", "address" => @address}]
    smaller = [%{"fromBlock" => "0x1", "toBlock" => "0xa", "address" => @address}]

    for {successes, successful_params, retractions} <- [{1, larger, 1}, {128, smaller, 0}] do
      fleets =
        for name <- ["retraction-primary", "retraction-backup"], do: Fleet.start!(self(), name)

      [primary, backup] = fleets

      try do
        tenant = Tenant.open!(fleets)

        try do
          before = span_retractions()
          {:ok, plan} = Catalog.get_routing_plan(Catalog.snapshot(), tenant.profile, 31_337)
          provider = Enum.find(plan.providers, &(&1.id == primary.name))

          subject =
            TransportRegistry.learning_subject_for(tenant.profile, 31_337, :http, provider.config)

          scope = %{
            subject: subject.id,
            profile: tenant.profile,
            chain_id: 31_337,
            partition: :client_logs
          }

          Fleet.script(
            primary,
            method,
            [],
            {:error, -32_600, "You can make eth_getLogs requests with up to a 10 block range"}
          )

          Fleet.script(backup, method, [], {:answer, []})

          for _ <- 1..2 do
            call(tenant, fleets, method, params, primary.name)
            settle()
          end

          {_, sends} = call(tenant, fleets, method, params)

          expected =
            if System.get_env("LASSO_PROVIDER_KNOWLEDGE_SPAN_LIMIT_MODE") == "off",
              do: [primary.name, backup.name],
              else: [backup.name]

          assert Enum.map(sends, & &1.fleet) == expected
          assert span_retractions() == before
          assert {:ok, %{kind: :span_limit}} = ProviderKnowledge.span_limit(scope, :logs)

          Fleet.script(primary, method, [], {:answer, []})

          for _ <- 1..successes do
            {response, _} = call(tenant, fleets, method, successful_params, primary.name)
            assert response.body["result"] == []
            settle()
          end

          assert span_retractions() == before + retractions
          assert :unknown = ProviderKnowledge.span_limit(scope, :logs)

          {response, sends} = call(tenant, fleets, method, params)
          assert response.body["result"] == []
          assert Enum.map(sends, & &1.fleet) == [primary.name]
          settle()
          assert span_retractions() == before + retractions
          uri = URI.parse(tenant.rpc_url)

          assert {:ok, %{status: 200, body: metrics}} =
                   Finch.build(:get, "#{uri.scheme}://#{uri.host}:#{uri.port}/metrics")
                   |> Finch.request(Lasso.Finch)

          series =
            metrics
            |> String.split("\n")
            |> Enum.filter(&String.starts_with?(&1, "lasso_provider_knowledge_"))

          assert length(series) == 6

          assert Enum.all?(
                   series,
                   &(not String.contains?(&1, ["provider=", "profile=", "subject="]))
                 )
        after
          Tenant.close!(tenant)
        end
      after
        Enum.each(fleets, &Fleet.stop/1)
      end
    end
  end

  test "a learned-feedback worker crash leaves RPC serving and routing owners alive" do
    fleet = Fleet.start!(self(), "feedback-recovery")
    tenant = Tenant.open!([fleet])

    owners =
      Map.new(
        [Lasso.Config.ConfigStore, Lasso.Providers.Catalog.Owner, LassoWeb.Endpoint],
        &{&1, Process.whereis(&1)}
      )

    try do
      stats =
        Lasso.Core.ProjectionDispatcher.stats(
          Lasso.ExecutionProjectionDispatcher,
          :learned_feedback
        )

      worker = stats.shards[0].worker
      Process.exit(worker, :kill)
      {response, sends} = call(tenant, [fleet], "eth_getBalance", [@address, "latest"])
      assert response.body["result"] == "0x10"
      assert Enum.map(sends, & &1.fleet) == [fleet.name]

      Settle.await("feedback worker replaced", fn ->
        case Lasso.Core.ProjectionDispatcher.stats(
               Lasso.ExecutionProjectionDispatcher,
               :learned_feedback
             ) do
          %{shards: %{0 => %{worker: replacement}}} when replacement != worker ->
            {:ok, replacement}

          other ->
            other
        end
      end)

      uri = URI.parse(tenant.rpc_url)

      assert {:ok, %{status: 200}} =
               Finch.build(:get, "#{uri.scheme}://#{uri.host}:#{uri.port}/api/health")
               |> Finch.request(Lasso.Finch)

      for {name, pid} <- owners, do: assert(Process.whereis(name) == pid)
    after
      Tenant.close!(tenant)
      Fleet.stop(fleet)
    end
  end

  defp span_retractions do
    %{count: count} =
      Enum.find(ReadModel.retractions(), &(&1.kind == :span_limit and &1.reason == :contradicted))

    count
  end

  defp settle do
    Settle.await("learned feedback applied", fn ->
      case Lasso.Core.ProjectionDispatcher.stats(
             Lasso.ExecutionProjectionDispatcher,
             :learned_feedback
           ) do
        %{retained_items: 0} -> {:ok, :drained}
        stats -> stats
      end
    end)
  end

  defp observe_heads(tenant, fleets) do
    topic = Lasso.Topics.block_sync(tenant.profile, 31_337)
    :ok = Phoenix.PubSub.subscribe(Lasso.PubSub, topic)

    try do
      for fleet <- fleets do
        call(tenant, fleets, "eth_blockNumber", [], fleet.name)
        profile = tenant.profile
        provider = fleet.name
        assert_receive %HeadObserved{profile: ^profile, provider_id: ^provider}
      end
    after
      Phoenix.PubSub.unsubscribe(Lasso.PubSub, topic)
    end
  end

  defp call(tenant, fleets, method, params, provider \\ nil) do
    query = "?include_meta=body" <> if(provider, do: "&provider_override=" <> provider, else: "")
    credentials = %{rpc_url: tenant.rpc_url <> query}

    Settle.closed(fn -> Rpc.call(credentials, method, params) end, fleets, %{
      method: method,
      params: params
    })
  end
end
