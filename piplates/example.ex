defmodule Piplates.Example do

  def start(_type, _args) do

    children = [
      {Piplates.DAQC2,[]},
    ]

    opts = [
      strategy: :one_for_one,
      name: Piplates.Example.Supervisor,
      max_restarts: 99999,
    ]

    Supervisor.start_link(children, opts)

  end

end