defmodule LassoWeb.Dashboard.SimulatorJavascriptTest do
  use ExUnit.Case, async: true

  @tag timeout: 30_000
  test "browser simulator preserves terminal request outcomes" do
    node = System.find_executable("node")
    assert node, "Node.js 18+ is required to verify the dashboard simulator"

    {output, status} =
      System.cmd(node, ["--test", "test/javascript/lasso_simulator_test.mjs"],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end
end
