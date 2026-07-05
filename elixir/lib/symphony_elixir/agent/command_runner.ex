defmodule SymphonyElixir.Agent.CommandRunner do
  @moduledoc false

  require Logger

  alias SymphonyElixir.{Agent.CommandTemplate, SSH}

  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000

  @type result :: %{
          output: String.t(),
          exit_status: non_neg_integer()
        }

  @spec run(String.t(), Path.t(), String.t() | nil, non_neg_integer(), (map() -> term()), map()) ::
          {:ok, result()} | {:error, term()}
  def run(command, workspace, worker_host, timeout_ms, on_message, metadata)
      when is_binary(command) and is_binary(workspace) and is_integer(timeout_ms) and timeout_ms > 0 and
             is_function(on_message, 1) and is_map(metadata) do
    with {:ok, port} <- start_port(command, workspace, worker_host) do
      await_exit(port, timeout_ms, on_message, metadata, [])
    end
  end

  defp start_port(command, workspace, nil) do
    case System.find_executable("bash") do
      nil ->
        {:error, :bash_not_found}

      executable ->
        port =
          Port.open(
            {:spawn_executable, String.to_charlist(executable)},
            [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              args: [~c"-lc", String.to_charlist(command)],
              cd: String.to_charlist(workspace),
              line: @port_line_bytes
            ]
          )

        {:ok, port}
    end
  end

  defp start_port(command, workspace, worker_host) when is_binary(worker_host) do
    remote_command = "cd #{CommandTemplate.shell_escape(workspace)} && exec #{command}"
    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  defp await_exit(port, timeout_ms, on_message, metadata, output_chunks) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = to_string(chunk)
        emit_output(on_message, metadata, line)
        await_exit(port, timeout_ms, on_message, metadata, ["\n", line | output_chunks])

      {^port, {:data, {:noeol, chunk}}} ->
        line = to_string(chunk)
        emit_output(on_message, metadata, line)
        await_exit(port, timeout_ms, on_message, metadata, [line | output_chunks])

      {^port, {:exit_status, 0}} ->
        {:ok, %{output: output_from_chunks(output_chunks), exit_status: 0}}

      {^port, {:exit_status, status}} when is_integer(status) ->
        {:error, {:command_exit, status, output_from_chunks(output_chunks)}}
    after
      timeout_ms ->
        stop_port(port)
        {:error, :turn_timeout}
    end
  end

  defp emit_output(on_message, metadata, line) when is_function(on_message, 1) do
    text = String.slice(line, 0, @max_stream_log_bytes)

    if String.trim(text) != "" do
      Logger.debug("Agent command output: #{text}")
    end

    message =
      metadata
      |> Map.put(:event, :notification)
      |> Map.put(:timestamp, DateTime.utc_now())
      |> Map.put(:payload, %{line: line})
      |> Map.put(:raw, line)

    on_message.(message)
  end

  defp output_from_chunks(chunks) when is_list(chunks) do
    chunks
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError -> :ok
        end
    end
  end
end
