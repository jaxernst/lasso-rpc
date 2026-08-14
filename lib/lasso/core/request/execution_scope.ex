defmodule Lasso.Core.Request.ExecutionScope do
  @moduledoc false

  defmodule CallerGuard do
    @moduledoc false

    @enforce_keys [:caller_pid, :monitor_ref]
    defstruct @enforce_keys

    @type t :: %__MODULE__{caller_pid: pid(), monitor_ref: reference()}
  end

  @enforce_keys [:owner_pid]
  defstruct [:owner_pid, :caller_pid, :deadline_us]

  @opaque t :: %__MODULE__{
            owner_pid: pid(),
            caller_pid: pid() | nil,
            deadline_us: integer() | nil
          }

  @spec local(pid(), integer() | nil) :: t()
  def local(owner_pid \\ self(), deadline_us \\ nil) do
    validate_owner!(owner_pid)
    validate_deadline!(deadline_us)
    %__MODULE__{owner_pid: owner_pid, deadline_us: deadline_us}
  end

  @spec monitored(pid(), pid(), integer() | nil) :: t()
  def monitored(owner_pid, caller_pid, deadline_us \\ nil) do
    validate_owner!(owner_pid)
    validate_caller!(owner_pid, caller_pid)
    validate_deadline!(deadline_us)

    %__MODULE__{
      owner_pid: owner_pid,
      caller_pid: caller_pid,
      deadline_us: deadline_us
    }
  end

  @doc false
  @spec open(t()) :: CallerGuard.t() | nil
  def open(%__MODULE__{owner_pid: owner_pid} = scope) do
    if owner_pid != self() do
      raise ArgumentError, "execution scope must be opened by its owner process"
    end

    open_caller_guard(scope.caller_pid)
  end

  @doc false
  @spec close(CallerGuard.t() | nil) :: :ok
  def close(nil), do: :ok

  def close(%CallerGuard{monitor_ref: monitor_ref}) do
    Process.demonitor(monitor_ref, [:flush])
    :ok
  end

  @doc false
  @spec caller_alive?(CallerGuard.t() | nil) :: boolean()
  def caller_alive?(nil), do: true
  def caller_alive?(%CallerGuard{caller_pid: caller_pid}), do: Process.alive?(caller_pid)

  @doc false
  @spec caller_monitor(CallerGuard.t() | nil) :: reference() | nil
  def caller_monitor(nil), do: nil
  def caller_monitor(%CallerGuard{monitor_ref: monitor_ref}), do: monitor_ref

  @doc false
  @spec caller_pid(CallerGuard.t() | nil) :: pid() | nil
  def caller_pid(nil), do: nil
  def caller_pid(%CallerGuard{caller_pid: caller_pid}), do: caller_pid

  @doc false
  @spec deadline_us(t()) :: integer() | nil
  def deadline_us(%__MODULE__{deadline_us: deadline_us}), do: deadline_us

  defp open_caller_guard(nil), do: nil

  defp open_caller_guard(caller_pid) do
    %CallerGuard{
      caller_pid: caller_pid,
      monitor_ref: Process.monitor(caller_pid)
    }
  end

  defp validate_owner!(owner_pid) when is_pid(owner_pid), do: :ok

  defp validate_owner!(_owner_pid) do
    raise ArgumentError, "execution scope owner must be a pid"
  end

  defp validate_caller!(owner_pid, caller_pid)
       when is_pid(caller_pid) and owner_pid != caller_pid,
       do: :ok

  defp validate_caller!(owner_pid, owner_pid) do
    raise ArgumentError, "monitored caller must differ from the execution owner"
  end

  defp validate_caller!(_owner_pid, _caller_pid) do
    raise ArgumentError, "execution scope caller must be a pid"
  end

  defp validate_deadline!(nil), do: :ok
  defp validate_deadline!(deadline_us) when is_integer(deadline_us), do: :ok

  defp validate_deadline!(_deadline_us) do
    raise ArgumentError, "execution scope deadline must be an absolute monotonic integer"
  end
end
