defmodule SymphonyElixirWeb.RawBodyReader do
  @moduledoc """
  Stores the raw HTTP request body before Plug.Parsers decodes it.

  Linear signs the exact request body bytes, so webhook signature
  verification must use this captured body rather than a re-encoded JSON map.
  """

  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        {:ok, body, append_raw_body(conn, body)}

      {:more, body, conn} ->
        {:more, body, append_raw_body(conn, body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp append_raw_body(conn, body) when is_binary(body) do
    existing = conn.private[:symphony_raw_body] || ""
    Plug.Conn.put_private(conn, :symphony_raw_body, existing <> body)
  end
end
