defmodule Lasso.Observability.PrometheusRequestSeriesTest do
  use ExUnit.Case, async: false

  alias Lasso.Observability.Prometheus

  @writers 16

  setup do
    unless Process.whereis(Prometheus), do: start_supervised!(Prometheus)
    :ok
  end

  test "concurrent first observations of a request series share one row" do
    for round <- 1..400 do
      provider = "series-race-#{round}-#{System.unique_integer([:positive])}"
      metadata = %{chain_id: 1, provider_id: provider, method: "eth_call", result: :success}
      parent = self()

      writers =
        for _ <- 1..@writers do
          spawn_link(fn ->
            receive do
              :go -> :ok
            end

            Prometheus.handle_event(
              [:lasso, :rpc, :request, :stop],
              %{duration: 1},
              metadata,
              nil
            )

            send(parent, {:observed, self()})
          end)
        end

      Enum.each(writers, &send(&1, :go))
      for writer <- writers, do: assert_receive({:observed, ^writer}, 5_000)

      rows =
        Prometheus.scrape()
        |> String.split("\n")
        |> Enum.filter(
          &String.starts_with?(&1, ~s(lasso_rpc_requests_total{chain="1",provider="#{provider}"))
        )

      assert rows == [
               ~s(lasso_rpc_requests_total{chain="1",provider="#{provider}",method="eth_call",outcome="success"} #{@writers})
             ]
    end
  end
end
