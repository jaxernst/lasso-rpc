defmodule Lasso.BlockPublication.Supervisor do
  @moduledoc "Restarts the publication coordinator and its owned background tasks together."
  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Task.Supervisor, name: Lasso.BlockPublication.TaskSupervisor},
      Lasso.BlockPublication.Runtime
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
