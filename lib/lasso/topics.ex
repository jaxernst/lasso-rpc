defmodule Lasso.Topics do
  @moduledoc """
  Centralized PubSub topic schema.

  Every `Phoenix.PubSub.broadcast/3`, `subscribe/2`, and `unsubscribe/2`
  call should reference a function in this module rather than
  constructing topic strings inline. The single point of definition lets
  us change topic shape without grepping callsites and avoids fragile
  topic encodings such as `inspect/1`.

  All `profile_id` parameters are opaque strings (D19) — plain string
  interpolation is safe; no `inspect/1` encoding needed.
  """

  @type profile_id :: String.t()
  @type chain_id :: pos_integer()
  @type instance_id :: String.t()

  ## Profile-scoped

  @spec routing_decision(profile_id()) :: String.t()
  def routing_decision(profile_id), do: "routing:decisions:#{profile_id}"

  @spec sync_updates(profile_id()) :: String.t()
  def sync_updates(profile_id), do: "sync:updates:#{profile_id}"

  @spec block_cache_updates(profile_id()) :: String.t()
  def block_cache_updates(profile_id), do: "block_cache:updates:#{profile_id}"

  @spec config_profile_updated(profile_id()) :: String.t()
  def config_profile_updated(profile_id), do: "config:profile_updated:#{profile_id}"

  ## Profile + chain

  @spec circuit_event(profile_id(), chain_id()) :: String.t()
  def circuit_event(profile_id, chain_id), do: "circuit:events:#{profile_id}:#{chain_id}"

  @spec block_sync(profile_id(), chain_id()) :: String.t()
  def block_sync(profile_id, chain_id), do: "block_sync:#{profile_id}:#{chain_id}"

  @spec provider_event(profile_id(), chain_id()) :: String.t()
  def provider_event(profile_id, chain_id), do: "provider:events:#{profile_id}:#{chain_id}"

  @spec subscription_event(profile_id(), chain_id()) :: String.t()
  def subscription_event(profile_id, chain_id),
    do: "subscription:lifecycle:#{profile_id}:#{chain_id}"

  @spec ws_connection(profile_id(), chain_id()) :: String.t()
  def ws_connection(profile_id, chain_id), do: "ws:conn:#{profile_id}:#{chain_id}"

  ## Instance-scoped

  @spec instance_config_updated(instance_id()) :: String.t()
  def instance_config_updated(instance_id), do: "instance_config_updated:#{instance_id}"

  @spec ws_subs_instance(instance_id()) :: String.t()
  def ws_subs_instance(instance_id), do: "ws:subs:instance:#{instance_id}"

  @spec ws_conn_instance(instance_id()) :: String.t()
  def ws_conn_instance(instance_id), do: "ws:conn:instance:#{instance_id}"

  @spec instance_sub_manager_restarted(chain_id()) :: String.t()
  def instance_sub_manager_restarted(chain_id),
    do: "instance_sub_manager:restarted:#{chain_id}"

  ## Global

  @spec cluster_topology() :: String.t()
  def cluster_topology, do: "cluster:topology"

  @spec metrics_store_cache_warmed() :: String.t()
  def metrics_store_cache_warmed, do: "metrics_store:cache_warmed"

  @spec config_profile_changes() :: String.t()
  def config_profile_changes, do: "config:profile_changes"
end
