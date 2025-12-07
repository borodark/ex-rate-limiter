defmodule RateLimiterWeb.Telemetry do
  @moduledoc """
  Telemetry metrics for LiveDashboard monitoring.

  Provides real-time metrics for:
  - HTTP request performance
  - Rate limiter operations
  - System resources
  - VM statistics
  """

  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      {:telemetry_poller, measurements: periodic_measurements(), period: 1_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),

      # HTTP Request Metrics
      counter("phoenix.endpoint.start.count",
        description: "Total HTTP requests"
      ),
      counter("phoenix.endpoint.stop.count",
        description: "Completed HTTP requests"
      ),

      # Rate Limiter Specific Metrics
      summary("rate_limiter.check.duration",
        unit: {:native, :millisecond},
        description: "Rate limit check duration"
      ),
      counter("rate_limiter.check.count",
        description: "Rate limit checks performed"
      ),
      counter("rate_limiter.allowed.count",
        description: "Requests allowed"
      ),
      counter("rate_limiter.blocked.count",
        description: "Requests blocked"
      ),

      # Bandit/HTTP Server Metrics
      summary("bandit.request.duration",
        unit: {:native, :millisecond}
      ),
      counter("bandit.request.count"),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :megabyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io"),
      summary("vm.system_counts.process_count"),
      summary("vm.system_counts.atom_count"),
      summary("vm.system_counts.port_count")
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      {__MODULE__, :measure_system, []},
      {:process_info,
       event: [:vm, :system_counts],
       name: __MODULE__,
       keys: [:message_queue_len, :memory]}
    ]
  end

  def measure_system do
    # Custom system measurements
    :telemetry.execute(
      [:vm, :memory],
      %{
        total: :erlang.memory(:total),
        processes: :erlang.memory(:processes),
        atom: :erlang.memory(:atom),
        binary: :erlang.memory(:binary),
        ets: :erlang.memory(:ets)
      },
      %{}
    )

    :telemetry.execute(
      [:vm, :total_run_queue_lengths],
      %{
        total: :erlang.statistics(:total_run_queue_lengths),
        cpu: :erlang.statistics(:run_queue),
        io: :erlang.statistics(:total_run_queue_lengths) - :erlang.statistics(:run_queue)
      },
      %{}
    )

    :telemetry.execute(
      [:vm, :system_counts],
      %{
        process_count: :erlang.system_info(:process_count),
        atom_count: :erlang.system_info(:atom_count),
        port_count: :erlang.system_info(:port_count)
      },
      %{}
    )
  end
end
