defmodule PurpleFlowWeb.MCP.ClientDocument do
  @moduledoc """
  Learns who's asking to sign in to `/mcp`. An MCP app's `client_id` is an
  `https` address serving a small JSON document about it, with its name and
  the addresses it may be sent back to
  ([Client ID Metadata Documents](https://datatracker.ietf.org/doc/html/draft-ietf-oauth-client-id-metadata-document-00)).
  So nothing needs registering in advance. See [specs/270](specs/270_mcp_files.md).

  The fetch is one `GET`, `https` only, no redirects followed, 5 seconds,
  and at most 5 KB.
  """

  @max_bytes 5_120

  @doc """
  Fetches and checks the document at `client_id`. Returns
  `{:ok, %{name: name, redirect_uris: [uri]}}`, or `{:error, why}` with a
  sentence for the person signing in. A document without a `client_name`
  is named after its host.
  """
  def fetch(client_id) do
    with {:ok, uri} <- https(client_id),
         {:ok, body} <- get(client_id),
         {:ok, document} <- decode(body),
         :ok <- same_id(document, client_id),
         {:ok, redirect_uris} <- redirect_uris(document) do
      {:ok, %{name: name(document, uri), redirect_uris: redirect_uris}}
    end
  end

  defp https(client_id) when is_binary(client_id) do
    case URI.parse(client_id) do
      %URI{scheme: "https", host: host} = uri when host not in [nil, ""] -> {:ok, uri}
      _ -> {:error, "the app's client_id isn't an https address"}
    end
  end

  defp https(_), do: {:error, "the request has no client_id"}

  defp get(url) do
    [
      method: :get,
      url: url,
      redirect: false,
      retry: false,
      decode_body: false,
      receive_timeout: 5_000,
      connect_options: [timeout: 5_000],
      # Stops reading once the document is too big, rather than taking in
      # whatever a server sends.
      into: fn {:data, data}, {req, resp} ->
        body = resp.body <> data

        if byte_size(body) > @max_bytes,
          do: {:halt, {req, %{resp | body: :too_large}}},
          else: {:cont, {req, %{resp | body: body}}}
      end
    ]
    |> Keyword.merge(Application.get_env(:purple_flow, :mcp_client_req_options, []))
    |> Req.new()
    |> Req.request()
    |> case do
      {:ok, %{body: :too_large}} -> {:error, "the app's document is over 5 KB"}
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, "the app's document answered #{status}"}
      {:error, e} -> {:error, "couldn't fetch the app's document: #{Exception.message(e)}"}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{} = document} -> {:ok, document}
      _ -> {:error, "the app's document isn't a JSON object"}
    end
  end

  defp same_id(%{"client_id" => id}, id), do: :ok
  defp same_id(_document, _id), do: {:error, "the app's document names a different client_id"}

  defp redirect_uris(%{"redirect_uris" => [_ | _] = uris}) do
    if Enum.all?(uris, &is_binary/1),
      do: {:ok, uris},
      else: {:error, "the app's document has a redirect address that isn't text"}
  end

  defp redirect_uris(_document), do: {:error, "the app's document lists no redirect addresses"}

  defp name(%{"client_name" => name}, _uri) when is_binary(name) and name != "", do: name
  defp name(_document, uri), do: uri.host
end
