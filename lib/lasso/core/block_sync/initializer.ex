defmodule Lasso.BlockSync.Initializer do
  @moduledoc """
  Populates BlockSync workers for all unique instances on a given chain.

  Called from `start_shared_infrastructure/0` after InstanceSupervisors are started.
  """

  require Logger

  alias Lasso.BlockSync.Supervisor, as: BlockSyncSupervisor
  alias Lasso.Providers.Catalog

  @spec start_workers_for_chain(pos_integer()) :: :ok
  def start_workers_for_chain(chain_id) when is_integer(chain_id) and chain_id > 0 do
    instance_ids = Catalog.list_instances_for_chain(chain_id)
    BlockSyncSupervisor.start_all_workers(chain_id, instance_ids)
  end
end
