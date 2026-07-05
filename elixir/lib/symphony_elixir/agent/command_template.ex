defmodule SymphonyElixir.Agent.CommandTemplate do
  @moduledoc false

  @type render_context :: %{
          optional(:prompt) => String.t(),
          optional(:model) => String.t() | nil,
          optional(:model_arg) => String.t(),
          optional(:workspace) => String.t(),
          optional(:issue_identifier) => String.t() | nil,
          optional(:max_turns) => integer() | String.t()
        }

  @spec render(String.t(), render_context()) :: String.t()
  def render(command, context) when is_binary(command) and is_map(context) do
    Enum.reduce(context, command, fn {key, value}, rendered ->
      string_key = Atom.to_string(key)
      replacement = template_value(key, value)

      rendered
      |> String.replace("{{ #{string_key} }}", replacement)
      |> String.replace("{{#{string_key}}}", replacement)
    end)
  end

  @spec render_model_arg(String.t() | nil) :: String.t()
  def render_model_arg(model), do: render_model_arg(model, "--model")

  @spec render_model_arg(String.t() | nil, String.t()) :: String.t()
  def render_model_arg(model, flag) when is_binary(model) and is_binary(flag) do
    case String.trim(model) do
      "" -> ""
      trimmed -> flag <> " " <> shell_escape(trimmed)
    end
  end

  def render_model_arg(_model, _flag), do: ""

  @spec render_prompt(String.t(), String.t()) :: String.t()
  def render_prompt(command, prompt) when is_binary(command) and is_binary(prompt) do
    if String.contains?(command, ["{{ prompt }}", "{{prompt}}"]), do: command, else: String.trim(command) <> " " <> shell_escape(prompt)
  end

  @spec inject_codex_model_arg(String.t(), String.t() | nil) :: String.t()
  def inject_codex_model_arg(command, nil), do: command

  def inject_codex_model_arg(command, model) when is_binary(command) and is_binary(model) do
    model_arg = render_model_arg(model)

    cond do
      model_arg == "" ->
        command

      String.contains?(command, ["{{ model_arg }}", "{{model_arg}}", "{{ model }}", "{{model}}"]) ->
        render(command, %{model: model, model_arg: model_arg})

      Regex.match?(~r/\sapp-server(\s|$)/, command) ->
        Regex.replace(~r/\sapp-server(\s|$)/, command, " " <> model_arg <> " app-server\\1", global: false)

      true ->
        command <> " " <> model_arg
    end
  end

  @spec shell_escape(String.t()) :: String.t()
  def shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp template_value(:prompt, value) when is_binary(value), do: shell_escape(value)
  defp template_value(:model, value) when is_binary(value), do: shell_escape(value)
  defp template_value(:workspace, value) when is_binary(value), do: shell_escape(value)
  defp template_value(:issue_identifier, value) when is_binary(value), do: shell_escape(value)
  defp template_value(_key, nil), do: ""
  defp template_value(_key, value), do: to_string(value)
end
