defmodule Lasso.Test.HeadRecoveryPeer do
  @moduledoc false
  alias Lasso.RPC.HeadRecovery

  def configure({profile, chain}) do
    case Lasso.Config.ConfigStore.get_chain(profile, chain) do
      {:ok, %{head_policy: "local"}} ->
        :ok

      {:error, :not_found} ->
        Lasso.Config.ConfigStore.register_chain_runtime(profile, chain, %{
          head_policy: "local",
          providers: [],
          block_time_ms: 250,
          new_heads_monitoring: false
        })
    end
  end

  def seed(key, height) do
    hash = "0x" <> String.pad_leading(Integer.to_string(height, 16), 64, "0")
    :ets.insert(:lasso_accepted_heads, {key, height, hash, make_ref()})
    :ok
  end

  def floor(key), do: :ets.lookup(:lasso_accepted_heads, key)
  def hint(key), do: HeadRecovery.read(key)

  def notifications(enabled) do
    :sys.replace_state(HeadRecovery, fn state ->
      if enabled,
        do: Phoenix.PubSub.subscribe(Lasso.PubSub, "local_head_recovery:v1"),
        else: Phoenix.PubSub.unsubscribe(Lasso.PubSub, "local_head_recovery:v1")

      state
    end)

    :ok
  end

  def restart_worker do
    old = Process.whereis(HeadRecovery)
    :ok = Supervisor.terminate_child(Lasso.Supervisor, HeadRecovery)
    {:ok, new} = Supervisor.restart_child(Lasso.Supervisor, HeadRecovery)
    old != new
  end

  def generation, do: :ets.lookup_element(:lasso_accepted_heads, :generation, 2)
end
