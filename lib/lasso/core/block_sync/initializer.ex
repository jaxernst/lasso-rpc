defmodule Lasso.BlockSync.Initializer do
  @moduledoc """
  Populates BlockSync workers for all unique instances on a given chain.

  Called from `start_shared_infrastructure/0` after InstanceSupervisors are started.
  """

  require Logger

  alias Lasso.BlockSync.Supervisor, as: BlockSyncSupervisor
  alias Lasso.Providers.Catalog

  @spec start_workers_for_chain(String.t()) :: :ok
  def start_workers_for_chain(chain) do
    instance_ids = Catalog.list_instances_for_chain(chain)
    BlockSyncSupervisor.start_all_workers(chain, instance_ids)
  end
end
