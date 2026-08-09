defmodule OpenChat.Replication.Supervisor do
  @moduledoc """
  One Tailer per configured peer region. Started only when
  REPLICATION_MODE=multi_master; with no peers configured the region is
  emission-only (peers tail it, it tails nobody).
  """

  use Supervisor

  alias OpenChat.Config
  alias OpenChat.Replication.Tailer

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children =
      for peer <- Config.peer_regions() do
        Supervisor.child_spec({Tailer, peer}, id: {Tailer, peer.index})
      end

    Supervisor.init(children, strategy: :one_for_one)
  end
end
