defmodule Briefly.Entry do
  @moduledoc false

  @dir_table __MODULE__.Dir
  @path_table __MODULE__.Path
  @max_attempts 10

  def server do
    Process.whereis(__MODULE__) ||
      raise "could not find process Briefly.Entry. Have you started the :briefly application?"
  end

  use GenServer

  def start_link(init_arg) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc false
  # todo: remove deprecation warning on v0.6.0.
  def create(%{monitor_pid: pid} = options) do
    IO.warn("the :monitor_pid option is deprecated, please use Briefly.give_away/3 instead.")

    with {:ok, path} <- create(Map.delete(options, :monitor_pid)) do
      :ok = give_away(path, pid, self())
      {:ok, path}
    end
  end

  def create(%{} = options) do
    case ensure_tmp() do
      {:ok, tmp} ->
        open(options, tmp, 0)

      {:no_tmp, _} = error ->
        error
    end
  end

  @doc false
  def cleanup(pid) do
    case :ets.lookup(@dir_table, pid) do
      [{pid, _tmp}] ->
        :ets.delete(@dir_table, pid)

        entries = :ets.lookup(@path_table, pid)
        Enum.each(entries, &delete_path/1)

        for {_path, path} <- entries, do: path

      [] ->
        []
    end
  end

  @doc false
  def give_away(path, to_pid, from_pid)
      when is_binary(path) and is_pid(to_pid) and is_pid(from_pid) do
    with [{^from_pid, _tmp}] <- :ets.lookup(@dir_table, from_pid),
         true <- path_owner?(from_pid, path) do
      case :ets.lookup(@dir_table, to_pid) do
        [{^to_pid, _tmp}] ->
          :ets.insert(@path_table, {to_pid, path})
          :ets.delete_object(@path_table, {from_pid, path})

          :ok

        [] ->
          server = server()

          {:ok, tmp} = generate_tmp_dir()
          :ok = GenServer.call(server, {:give_away, to_pid, tmp, path})

          :ets.delete_object(@path_table, {from_pid, path})

          :ok
      end
    else
      _ ->
        {:error, :unknown_path}
    end
  end

  ## Callbacks
  @impl true
  def init(_init_arg) do
    Process.flag(:trap_exit, true)
    tmp = Briefly.Config.directory() |> Path.expand()
    cwd = Path.join(File.cwd!(), "tmp")
    :persistent_term.put(__MODULE__, [tmp, cwd])
    :ets.new(@dir_table, [:named_table, :public, :set])
    :ets.new(@path_table, [:named_table, :public, :duplicate_bag])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:give_away, pid, tmp, path}, _from, state) do
    # Since we are writing on behalf of another process, we need to make sure
    # the monitor and writing to the tables happen within the same operation.
    Process.monitor(pid)
    :ets.insert_new(@dir_table, {pid, tmp})
    :ets.insert(@path_table, {pid, path})

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:monitor, pid}, state) do
    Process.monitor(pid)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    cleanup(pid)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    folder = fn entry, :ok -> delete_path(entry) end
    :ets.foldl(folder, :ok, @path_table)
  end

  ## Helpers

  defp ensure_tmp() do
    pid = self()

    case :ets.lookup(@dir_table, pid) do
      [{^pid, tmp}] ->
        {:ok, tmp}

      [] ->
        server = server()
        GenServer.cast(server, {:monitor, pid})

        with {:ok, tmp} <- generate_tmp_dir() do
          true = :ets.insert_new(@dir_table, {pid, tmp})
          {:ok, tmp}
        end
    end
  end

  defp generate_tmp_dir() do
    tmp_roots = :persistent_term.get(__MODULE__)
    {mega, _, _} = :os.timestamp()
    subdir = "briefly-" <> i(mega)

    if tmp = Enum.find_value(tmp_roots, &write_tmp_dir(Path.join(&1, subdir))) do
      {:ok, tmp}
    else
      {:no_tmp, tmp_roots}
    end
  end

  defp write_tmp_dir(path) do
    case File.mkdir_p(path) do
      :ok -> path
      {:error, _} -> nil
    end
  end

  defp open(%{directory: true} = options, tmp, attempts) when attempts < @max_attempts do
    path = path(options, tmp)

    case File.mkdir_p(path) do
      :ok ->
        :ets.insert(@path_table, {self(), path})
        {:ok, path}

      {:error, reason} when reason in [:eexist, :eacces] ->
        open(options, tmp, attempts + 1)
    end
  end

  defp open(options, tmp, attempts) when attempts < @max_attempts do
    path = path(options, tmp)

    case :file.write_file(path, "", [:write, :raw, :exclusive, :binary]) do
      :ok ->
        :ets.insert(@path_table, {self(), path})
        {:ok, path}

      {:error, reason} when reason in [:eexist, :eacces] ->
        open(options, tmp, attempts + 1)
    end
  end

  defp open(_prefix, tmp, attempts) do
    {:too_many_attempts, tmp, attempts}
  end

  defp path(options, tmp) do
    sec = :os.system_time(:seconds)
    rand = :rand.uniform(999_999_999_999)
    scheduler_id = :erlang.system_info(:scheduler_id)

    tmp <>
      "/" <>
      prefix(options) <>
      "-" <> i(sec) <> "-" <> i(rand) <> "-" <> i(scheduler_id) <> extname(options)
  end

  @compile {:inline, i: 1}
  defp i(integer), do: Integer.to_string(integer)

  defp prefix(%{prefix: value}), do: value
  defp prefix(_), do: Briefly.Config.default_prefix()

  defp extname(%{extname: value}), do: value
  defp extname(_), do: Briefly.Config.default_extname()

  defp path_owner?(pid, path) do
    owned_paths = :ets.lookup(@path_table, pid)
    Enum.any?(owned_paths, fn {_pid, p} -> p == path end)
  end

  defp delete_path({_pid, path}) do
    File.rm_rf(path)
    :ok
  end
end
