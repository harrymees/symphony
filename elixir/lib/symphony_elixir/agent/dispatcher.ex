defmodule SymphonyElixir.Agent.Dispatcher do
  @moduledoc false

  alias SymphonyElixir.Agent.Dispatchers.{ClaudeCode, Codex, OpenCode}

  @type selection :: SymphonyElixir.Agent.Selection.t()
  @type session :: map()

  @callback start_session(Path.t(), selection(), keyword()) :: {:ok, session()} | {:error, term()}
  @callback run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback stop_session(session()) :: :ok

  @spec start_session(selection(), Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(%{harness: harness} = selection, workspace, opts \\ []) do
    dispatcher_module(harness).start_session(workspace, selection, opts)
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(%{dispatcher: dispatcher} = session, prompt, issue, opts \\ []) when is_atom(dispatcher) do
    dispatcher.run_turn(session, prompt, issue, opts)
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{dispatcher: dispatcher} = session) when is_atom(dispatcher) do
    dispatcher.stop_session(session)
  end

  @spec dispatcher_module(String.t()) :: module()
  def dispatcher_module("codex"), do: Codex
  def dispatcher_module("claude_code"), do: ClaudeCode
  def dispatcher_module("opencode"), do: OpenCode
end
