defmodule Lasso.Observability.PrometheusRuntime do
  @moduledoc "Read-only BEAM and upstream snapshot evidence for Prometheus scrapes."

  alias Lasso.Core.Support.CircuitBreaker.Snapshot
  alias Lasso.Observability.PrometheusMetrics, as: Metrics
  alias Lasso.Providers.Catalog

  @doc "BEAM totals and pressure without dashboard subscriptions or scheduler flags."
  def scrape do
    memory = :erlang.memory()
    {reductions, _delta} = :erlang.statistics(:reductions)
    {collections, words, _} = :erlang.statistics(:garbage_collection)
    {{:input, input}, {:output, output}} = :erlang.statistics(:io)
    {uptime_ms, _delta} = :erlang.statistics(:wall_clock)

    family(
      "lasso_vm_memory_bytes",
      :gauge,
      "BEAM memory by non-additive allocation category",
      Enum.map(memory, fn {kind, bytes} -> {bytes, [kind: kind]} end)
    ) ++
      family("lasso_vm_processes", :gauge, "BEAM process count", [
        {:erlang.system_info(:process_count), []}
      ]) ++
      family("lasso_vm_process_limit", :gauge, "BEAM configured process limit", [
        {:erlang.system_info(:process_limit), []}
      ]) ++
      family("lasso_vm_ports", :gauge, "BEAM port count", [{:erlang.system_info(:port_count), []}]) ++
      family("lasso_vm_port_limit", :gauge, "BEAM configured port limit", [
        {:erlang.system_info(:port_limit), []}
      ]) ++
      family("lasso_vm_atoms", :gauge, "BEAM atom count", [{:erlang.system_info(:atom_count), []}]) ++
      family("lasso_vm_atom_limit", :gauge, "BEAM configured atom limit", [
        {:erlang.system_info(:atom_limit), []}
      ]) ++
      family("lasso_vm_ets_tables", :gauge, "BEAM ETS table count", [{length(:ets.all()), []}]) ++
      family("lasso_vm_run_queue", :gauge, "Runnable BEAM work", [
        {:erlang.statistics(:run_queue), []}
      ]) ++
      family("lasso_vm_schedulers", :gauge, "Online BEAM schedulers", [
        {:erlang.system_info(:schedulers_online), []}
      ]) ++
      family("lasso_vm_reductions_total", :counter, "Cumulative BEAM reductions", [
        {reductions, []}
      ]) ++
      family("lasso_vm_gc_collections_total", :counter, "Cumulative BEAM garbage collections", [
        {collections, []}
      ]) ++
      family(
        "lasso_vm_gc_reclaimed_words_total",
        :counter,
        "Cumulative words reclaimed by BEAM GC",
        [{words, []}]
      ) ++
      family("lasso_vm_io_bytes_total", :counter, "BEAM port I/O totals", [
        {input, [direction: "input"]},
        {output, [direction: "output"]}
      ]) ++
      family("lasso_vm_uptime_seconds", :gauge, "BEAM uptime", [{uptime_ms / 1000, []}]) ++
      family("lasso_build_info", :gauge, "Lasso runtime versions", [
        {1,
         [
           version: to_string(Application.spec(:lasso, :vsn)),
           otp: to_string(:erlang.system_info(:otp_release)),
           elixir: System.version()
         ]}
      ])
  end

  @doc "HTTP routing readiness using the same checks as /api/ready."
  def readiness_samples(chains) do
    chains
    |> Enum.uniq()
    |> Enum.flat_map(fn {profile, chain} ->
      check = Lasso.Providers.Readiness.check_chain(profile, chain)
      labels = [profile: profile, chain: chain]

      family("lasso_chain_ready", :gauge, "Eligible HTTP routes have fresh local head evidence", [
        {if(check.status == "ready", do: 1, else: 0), labels}
      ]) ++
        family("lasso_chain_eligible_upstreams", :gauge, "Eligible HTTP upstream alternatives", [
          {check.eligible_upstreams, labels}
        ])
    end)
  end

  @doc "Configured instance identity and circuit admission evidence for one route."
  def route_samples(profile, chain, provider, instance_id, head_observed?) do
    labels = [profile: profile, chain: chain, provider: provider]

    info =
      family("lasso_provider_info", :gauge, "Configured route to physical instance mapping", [
        {1, labels ++ [instance_id: instance_id || "unknown"]}
      ])

    head =
      family(
        "lasso_provider_head_observed",
        :gauge,
        "Fresh local head lag observation is available",
        [{if(head_observed?, do: 1, else: 0), labels}]
      )

    info ++
      head ++
      Enum.flat_map([:http, :ws], fn transport ->
        transport_labels = labels ++ [transport: transport]

        case instance_id && Snapshot.lookup({instance_id, transport}) do
          {:ok, s} ->
            family("lasso_circuit_ready", :gauge, "Circuit owner ready for admission", [
              {if(s.ready?, do: 1, else: 0), transport_labels}
            ]) ++
              family(
                "lasso_circuit_failures",
                :gauge,
                "Current circuit consecutive failure count",
                [{s.failure_count, transport_labels}]
              ) ++
              family(
                "lasso_circuit_half_open_capacity",
                :gauge,
                "Half-open circuit probe capacity",
                [{s.half_open_capacity, transport_labels}]
              ) ++
              family(
                "lasso_circuit_half_open_inflight",
                :gauge,
                "Admitted half-open probes in flight",
                [{s.half_open_inflight, transport_labels}]
              ) ++
              family(
                "lasso_circuit_recovery_delay_seconds",
                :gauge,
                "Remaining local circuit recovery delay",
                [{recovery_delay(s), transport_labels}]
              )

          _ ->
            []
        end
      end) ++ configured_transports(instance_id, labels)
  end

  defp configured_transports(id, labels) do
    case id && Catalog.get_instance(id) do
      {:ok, config} ->
        family(
          "lasso_provider_transport_configured",
          :gauge,
          "Transport configured for this upstream",
          [
            {1, labels ++ [transport: "http"]},
            {if(is_binary(config[:ws_url]) and config[:ws_url] != "", do: 1, else: 0),
             labels ++ [transport: "ws"]}
          ]
        )

      _ ->
        []
    end
  end

  defp recovery_delay(%{recovery_deadline_us: nil}), do: 0

  defp recovery_delay(%{recovery_deadline_us: deadline}),
    do: max(deadline - System.monotonic_time(:microsecond), 0) / 1_000_000

  @doc "Renders one metric family with its HELP and TYPE lines."
  def family(name, type, help, samples) do
    [
      "# HELP #{name} #{help}",
      "# TYPE #{name} #{type}"
      | Enum.map(samples, fn {value, labels} -> Metrics.sample(name, value, labels) end)
    ]
  end
end
