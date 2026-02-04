defmodule Lasso.MixProject do
  use Mix.Project

  def project do
    [
      app: :lasso,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      listeners: [Phoenix.CodeReloader],
      elixirc_paths: elixirc_paths(Mix.env()),
      releases: releases(),
      deps: deps(),
      dialyzer: dialyzer()
    ]
  end

  defp releases do
    [
      lasso: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end

  # Compile paths based on environment
  # Test support modules are only compiled in test environment
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    extra_apps =
      case Mix.env() do
        :dev -> [:logger, :runtime_tools, :wx, :observer, :tools]
        _ -> [:logger, :runtime_tools]
      end

    [
      extra_applications: extra_apps,
      mod: {Lasso.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:dotenvy, "~> 0.8.0"},
      {:jason, "~> 1.4"},
      {:websockex, "~> 0.4"},
      {:phoenix, "~> 1.8"},
      {:phoenix_pubsub, "~> 2.1"},
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix_html, "~> 4.0"},
      {:gettext, "~> 0.20"},
      {:plug_cowboy, "~> 2.6"},
      {:decimal, "~> 2.0"},
      {:yaml_elixir, "~> 2.9"},
      {:finch, "~> 0.18"},
      {:phoenix_live_dashboard, "~> 0.8", only: :dev},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2.0", runtime: Mix.env() == :dev},
      {:tailwind_formatter, "~> 0.4.2", only: :dev},
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"},
      {:mox, "~> 1.0", only: :test},
      {:cors_plug, "~> 3.0"},
      {:libcluster, "~> 3.3"},
      {:local_cluster, "~> 2.0", only: [:test]},
      {:recon, "~> 2.5"},
      {:observer_cli, "~> 1.7"},
      {:eflambe, "~> 0.3", only: :dev}
    ]
  end

  defp dialyzer do
    [
      plt_core_path: "priv/plts/core.plt",
      plt_local_path: "priv/plts/local.plt",
      ignore_warnings: ".dialyzer_ignore.exs",
      list_unused_filters: true
    ]
  end
end
