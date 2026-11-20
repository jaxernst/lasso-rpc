defmodule Lasso.Integration.MeasureProfileScriptTest do
  use ExUnit.Case, async: false
  use Lasso.Test.AnvilCase, prune_history: false

  alias Lasso.Config.ConfigStore
  alias Lasso.Providers

  @sender "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
  @recipient "0x000000000000000000000000000000000000dead"

  test "scripts/measure_profile.mjs completes against a profile and its providers",
       %{anvil_port: anvil_port, anvil_chain_id: chain} do
    slug = "public"

    on_exit(fn ->
      Lasso.ProfileChainSupervisor.stop_profile_chain(slug, chain)
      ConfigStore.unregister_chain_runtime(slug, chain)
      Providers.Catalog.build_from_config()
    end)

    :ok =
      ConfigStore.register_chain_runtime(slug, chain, %{
        display_name: "Anvil",
        block_time_ms: 1_000,
        providers: []
      })

    upstream = "http://127.0.0.1:#{anvil_port}"

    assert {:ok, "anvil"} =
             Providers.add_provider(chain, %{id: "anvil", name: "Anvil", url: upstream},
               profile: slug,
               validate: false
             )

    rpc_call!(anvil_port, "eth_sendTransaction", [
      %{"from" => @sender, "to" => @recipient, "value" => "0x1", "gas" => "0x5208"}
    ])

    rpc_call!(anvil_port, "anvil_mine", ["0x14"])

    port = LassoWeb.Endpoint.config(:http)[:port]

    out =
      Path.join(System.tmp_dir!(), "measure_profile_#{System.unique_integer([:positive])}.json")

    on_exit(fn -> File.rm(out) end)

    {output, status} =
      System.cmd(
        System.find_executable("node") || flunk("node executable not found"),
        [
          "scripts/measure_profile.mjs",
          "--lasso",
          "lasso=http://127.0.0.1:#{port}/rpc/profile/#{slug}/fastest/#{chain}",
          "--provider",
          "anvil=#{upstream}",
          "--calls",
          "12",
          "--rate",
          "10",
          "--out",
          out
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "Result: complete."

    %{"samples" => samples} = out |> File.read!() |> Jason.decode!()
    through_lasso = Enum.filter(samples, &(&1["endpoint"] == "lasso"))

    assert length(through_lasso) == 12
    assert Enum.all?(through_lasso, &(&1["ok"] and &1["meta"]["provider"] == "anvil"))
  end
end
