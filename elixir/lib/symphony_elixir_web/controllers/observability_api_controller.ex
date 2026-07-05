defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{Config, Orchestrator}
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @linear_timestamp_tolerance_ms 60_000

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec linear_webhook(Conn.t(), map()) :: Conn.t()
  def linear_webhook(conn, params) do
    settings = Config.settings!()

    with {:ok, secret} <- linear_webhook_secret(settings),
         {:ok, raw_body} <- raw_body(conn),
         :ok <- verify_linear_signature(conn, raw_body, secret),
         :ok <- verify_linear_timestamp(conn, params),
         {:ok, issue_id, metadata} <- linear_webhook_issue(params, settings) do
      case Orchestrator.notify_linear_webhook(orchestrator(), issue_id, metadata) do
        {:ok, payload} ->
          json(conn, payload)

        :unavailable ->
          error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
      end
    else
      {:error, :missing_secret} ->
        error_response(conn, 503, "webhook_secret_missing", "Linear webhook secret is not configured")

      {:error, :missing_raw_body} ->
        error_response(conn, 400, "missing_raw_body", "Webhook raw body was not captured")

      {:error, :invalid_signature} ->
        error_response(conn, 401, "invalid_signature", "Invalid webhook signature")

      {:error, :missing_timestamp} ->
        error_response(conn, 401, "missing_timestamp", "Missing Linear webhook timestamp")

      {:error, :stale_timestamp} ->
        error_response(conn, 401, "stale_timestamp", "Stale Linear webhook timestamp")

      {:ignored, reason} ->
        json(conn, %{queued: false, ignored: true, reason: reason})
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp linear_webhook_secret(settings) do
    case settings.webhooks.linear.secret do
      secret when is_binary(secret) and secret != "" -> {:ok, secret}
      _ -> {:error, :missing_secret}
    end
  end

  defp raw_body(conn) do
    case conn.private[:symphony_raw_body] do
      body when is_binary(body) and body != "" -> {:ok, body}
      _ -> {:error, :missing_raw_body}
    end
  end

  defp verify_linear_signature(conn, raw_body, secret) do
    received =
      conn
      |> get_req_header("linear-signature")
      |> List.first()
      |> normalize_signature()

    expected =
      :crypto.mac(:hmac, :sha256, secret, raw_body)
      |> Base.encode16(case: :lower)

    if secure_compare(received, expected), do: :ok, else: {:error, :invalid_signature}
  end

  defp verify_linear_timestamp(conn, params) do
    timestamp = params["webhookTimestamp"] || linear_timestamp_header(conn)

    with {:ok, timestamp_ms} <- parse_timestamp_ms(timestamp) do
      now_ms = System.system_time(:millisecond)

      if abs(now_ms - timestamp_ms) <= @linear_timestamp_tolerance_ms do
        :ok
      else
        {:error, :stale_timestamp}
      end
    else
      :error -> {:error, :missing_timestamp}
    end
  end

  defp linear_timestamp_header(conn) do
    conn
    |> get_req_header("linear-timestamp")
    |> List.first()
  end

  defp parse_timestamp_ms(value) when is_integer(value), do: {:ok, value}

  defp parse_timestamp_ms(value) when is_float(value), do: {:ok, round(value)}

  defp parse_timestamp_ms(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {timestamp_ms, ""} -> {:ok, timestamp_ms}
      _ -> :error
    end
  end

  defp parse_timestamp_ms(_value), do: :error

  defp normalize_signature(signature) when is_binary(signature) do
    signature
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_signature(_signature), do: ""

  defp secure_compare(received, expected)
       when is_binary(received) and is_binary(expected) and byte_size(received) == byte_size(expected) do
    Plug.Crypto.secure_compare(received, expected)
  end

  defp secure_compare(_received, _expected), do: false

  defp linear_webhook_issue(%{"type" => "Issue", "data" => %{"id" => issue_id} = data} = params, settings)
       when is_binary(issue_id) and issue_id != "" do
    if linear_webhook_project_matches?(data, params, settings) do
      {:ok, issue_id,
       %{
         source: :linear_webhook,
         action: params["action"],
         type: params["type"],
         identifier: data["identifier"],
         project_id: data["projectId"] || get_in(data, ["project", "id"]),
         updated_from: params["updatedFrom"] || params["updated_from"]
       }}
    else
      {:ignored, "project_mismatch"}
    end
  end

  defp linear_webhook_issue(_params, _settings), do: {:ignored, "unsupported_payload"}

  defp linear_webhook_project_matches?(data, params, settings) do
    configured_project_id = settings.webhooks.linear.project_id
    configured_project_slug = settings.tracker.project_slug
    project_ids = webhook_project_ids(data, params)

    cond do
      is_binary(configured_project_id) and configured_project_id != "" ->
        configured_project_id in project_ids

      is_binary(configured_project_slug) and configured_project_slug != "" ->
        case project_url(data) do
          url when is_binary(url) -> String.contains?(url, configured_project_slug)
          _ -> true
        end

      true ->
        true
    end
  end

  defp webhook_project_ids(data, params) do
    updated_from =
      case params["updatedFrom"] || params["updated_from"] do
        value when is_map(value) -> value
        _ -> %{}
      end

    [
      data["projectId"],
      get_in(data, ["project", "id"]),
      updated_from["projectId"],
      get_in(updated_from, ["project", "id"])
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp project_url(%{"project" => %{"url" => url}}), do: url
  defp project_url(_data), do: nil
end
