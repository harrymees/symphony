defmodule SymphonyElixir.Agent.Selection do
  @moduledoc """
  Resolves the agent harness and model for a Linear issue.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue

  @type t :: %{
          harness: String.t(),
          model: String.t() | nil,
          source: :workflow | :issue_label
        }

  @label_directive_regex ~r/^\s*(?:symphony[\s_-]*)?(?:agent|harness)\s*[:=\/]\s*(.+?)\s*$/i
  @model_directive_regex ~r/^\s*(?:symphony[\s_-]*)?model\s*[:=\/]\s*(.+?)\s*$/i

  @spec resolve(Issue.t()) :: {:ok, t()} | {:error, term()}
  def resolve(%Issue{} = issue) do
    resolve(issue, Config.settings!())
  end

  @spec resolve(Issue.t(), Schema.t()) :: {:ok, t()} | {:error, term()}
  def resolve(%Issue{} = issue, %Schema{} = settings) do
    with {:ok, label_harness} <- label_harness(issue.labels),
         {:ok, label_model} <- label_model(issue.labels) do
      harness = label_harness || settings.agent.harness
      model = label_model || normalized_model(settings.agent.model)
      source = if label_harness || label_model, do: :issue_label, else: :workflow

      {:ok, %{harness: harness, model: model, source: source}}
    end
  end

  @spec label_harness([String.t()]) :: {:ok, String.t() | nil} | {:error, term()}
  def label_harness(labels) when is_list(labels) do
    labels
    |> Enum.flat_map(&extract_harness_label/1)
    |> unique_directive(:harness)
  end

  @spec label_model([String.t()]) :: {:ok, String.t() | nil} | {:error, term()}
  def label_model(labels) when is_list(labels) do
    labels
    |> Enum.flat_map(&extract_model_label/1)
    |> unique_directive(:model)
  end

  defp extract_harness_label(label) when is_binary(label) do
    case Regex.run(@label_directive_regex, label, capture: :all_but_first) do
      [raw_harness] ->
        case Schema.normalize_agent_harness(raw_harness) do
          nil -> []
          harness -> [harness]
        end

      _ ->
        []
    end
  end

  defp extract_harness_label(_label), do: []

  defp extract_model_label(label) when is_binary(label) do
    case Regex.run(@model_directive_regex, label, capture: :all_but_first) do
      [raw_model] ->
        case normalized_model(raw_model) do
          nil -> []
          model -> [model]
        end

      _ ->
        []
    end
  end

  defp extract_model_label(_label), do: []

  defp unique_directive([], _field), do: {:ok, nil}

  defp unique_directive(values, field) when is_list(values) do
    case Enum.uniq(values) do
      [value] -> {:ok, value}
      conflicting -> {:error, {:conflicting_issue_agent_directives, field, conflicting}}
    end
  end

  defp normalized_model(model) when is_binary(model) do
    case String.trim(model) do
      "" -> nil
      value -> value
    end
  end

  defp normalized_model(_model), do: nil
end
