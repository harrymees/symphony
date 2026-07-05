defmodule SymphonyElixir.AgentDispatcherTest do
  use SymphonyElixir.TestSupport

  test "agent runner dispatches Claude Code command with selected model" do
    test_root = Path.join(System.tmp_dir!(), "symphony-elixir-claude-dispatcher-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      fake_agent = fake_agent_script!(test_root, "fake-claude", "fake-claude-session")
      trace_file = Path.join(test_root, "fake-claude.trace")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        agent_harness: "claude-code",
        agent_model: "claude-sonnet-4-5",
        claude_code_command: "SYMP_TEST_AGENT_TRACE=#{trace_file} #{fake_agent} {{ model_arg }} {{ prompt }}"
      )

      issue = %Issue{
        id: "issue-claude-dispatch",
        identifier: "MT-CLAUDE",
        title: "Dispatch Claude",
        state: "In Progress",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, self())

      assert_received {:codex_worker_update, "issue-claude-dispatch", %{event: :session_started, agent_harness: "claude_code", agent_model: "claude-sonnet-4-5"}}
      assert_received {:codex_worker_update, "issue-claude-dispatch", %{event: :turn_completed, session_id: "fake-claude-session"}}

      trace = File.read!(trace_file)
      assert trace =~ "--model"
      assert trace =~ "claude-sonnet-4-5"
      assert trace =~ "You are an agent for this repository."
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner dispatches GLM labels through the OpenCode harness" do
    test_root = Path.join(System.tmp_dir!(), "symphony-elixir-opencode-dispatcher-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      fake_agent = fake_agent_script!(test_root, "fake-opencode", "fake-opencode-session")
      trace_file = Path.join(test_root, "fake-opencode.trace")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        agent_harness: "codex",
        agent_model: "gpt-5.5",
        opencode_command: "SYMP_TEST_AGENT_TRACE=#{trace_file} #{fake_agent} {{ model_arg }} {{ prompt }}"
      )

      issue = %Issue{
        id: "issue-glm-dispatch",
        identifier: "MT-GLM",
        title: "Dispatch GLM",
        state: "In Progress",
        labels: ["agent:glm", "model:zai-coding-plan/glm-5.2"]
      }

      assert :ok = AgentRunner.run(issue, self())

      assert_received {:codex_worker_update, "issue-glm-dispatch", %{event: :session_started, agent_harness: "opencode", agent_model: "zai-coding-plan/glm-5.2"}}
      assert_received {:codex_worker_update, "issue-glm-dispatch", %{event: :turn_completed, session_id: "fake-opencode-session"}}

      trace = File.read!(trace_file)
      assert trace =~ "--model"
      assert trace =~ "zai-coding-plan/glm-5.2"
      assert trace =~ "You are an agent for this repository."
    after
      File.rm_rf(test_root)
    end
  end

  defp fake_agent_script!(test_root, name, session_id) do
    File.mkdir_p!(test_root)
    script = Path.join(test_root, name)

    File.write!(script, """
    #!/bin/sh
    trace_file="${SYMP_TEST_AGENT_TRACE:-#{Path.join(test_root, "agent.trace")}}"
    printf '%s\n' "$@" > "$trace_file"
    printf '{"session_id":"#{session_id}","usage":{"input_tokens":1,"output_tokens":2,"total_tokens":3}}\n'
    exit 0
    """)

    File.chmod!(script, 0o755)
    script
  end
end
