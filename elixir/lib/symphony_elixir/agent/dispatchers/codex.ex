defmodule SymphonyElixir.Agent.Dispatchers.Codex do
  @moduledoc false

  @behaviour SymphonyElixir.Agent.Dispatcher

  alias SymphonyElixir.{Agent.CommandTemplate, Codex.AppServer, Config}

  @impl true
  def start_session(workspace, selection, opts) do
    command = command_for_selection(selection)

    workspace
    |> AppServer.start_session(Keyword.put(opts, :command, command))
    |> case do
      {:ok, session} ->
        metadata = Map.merge(session.metadata, %{agent_harness: "codex", agent_model: selection[:model]})
        {:ok, Map.merge(session, %{dispatcher: __MODULE__, agent_harness: "codex", agent_model: selection[:model], metadata: metadata})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def run_turn(session, prompt, issue, opts) do
    AppServer.run_turn(session, prompt, issue, opts)
  end

  @impl true
  def stop_session(session), do: AppServer.stop_session(session)

  defp command_for_selection(selection) do
    Config.settings!().codex.command
    |> CommandTemplate.inject_codex_model_arg(selection[:model])
  end
end
