defmodule SymphonyElixir.Agent.Dispatchers.ClaudeCode do
  @moduledoc false

  @behaviour SymphonyElixir.Agent.Dispatcher

  alias SymphonyElixir.Agent.{CommandRunner, CommandTemplate}
  alias SymphonyElixir.Config

  @impl true
  def start_session(workspace, selection, opts) do
    {:ok,
     %{
       dispatcher: __MODULE__,
       agent_harness: "claude_code",
       agent_model: selection[:model],
       workspace: workspace,
       worker_host: Keyword.get(opts, :worker_host)
     }}
  end

  @impl true
  def run_turn(session, prompt, issue, opts) do
    settings = Config.settings!()
    session_id = session_id("claude", issue)
    metadata = metadata(session, session_id)
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    emit(on_message, metadata, :session_started, %{session_id: session_id})

    command = render_command(settings.claude_code.command, prompt, issue, session, settings, "--model")

    case CommandRunner.run(command, session.workspace, session.worker_host, settings.claude_code.turn_timeout_ms, on_message, metadata) do
      {:ok, %{output: output} = result} ->
        details = claude_completion_details(output, session_id)
        emit(on_message, metadata, :turn_completed, details)
        {:ok, Map.merge(result, %{session_id: details.session_id})}

      {:error, reason} ->
        emit(on_message, metadata, :turn_failed, %{reason: reason})
        {:error, reason}
    end
  end

  @impl true
  def stop_session(_session), do: :ok

  defp render_command(command, prompt, issue, session, settings, model_flag) do
    model_arg = CommandTemplate.render_model_arg(session.agent_model, model_flag)

    command
    |> CommandTemplate.render_prompt(prompt)
    |> CommandTemplate.render(%{
      prompt: prompt,
      model: session.agent_model,
      model_arg: model_arg,
      workspace: session.workspace,
      issue_identifier: issue.identifier,
      max_turns: settings.agent.max_turns
    })
  end

  defp claude_completion_details(output, fallback_session_id) do
    case Jason.decode(output) do
      {:ok, %{"session_id" => session_id} = payload} when is_binary(session_id) ->
        %{payload: payload, raw: output, session_id: session_id, usage: Map.get(payload, "usage")}

      {:ok, payload} ->
        %{payload: payload, raw: output, session_id: fallback_session_id}

      {:error, _reason} ->
        %{payload: %{output: output}, raw: output, session_id: fallback_session_id}
    end
  end

  defp metadata(session, session_id) do
    %{
      session_id: session_id,
      agent_harness: session.agent_harness,
      agent_model: session.agent_model
    }
  end

  defp emit(on_message, metadata, event, details) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp session_id(prefix, issue) do
    identifier = issue.identifier || issue.id || "issue"
    "#{prefix}-#{identifier}-#{System.unique_integer([:positive])}"
  end

  defp default_on_message(_message), do: :ok
end
