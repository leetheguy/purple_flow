defmodule PurpleFlowWeb.MCP.Server do
  @moduledoc """
  Answers one MCP message: JSON-RPC 2.0, as `POST /mcp` receives it
  (`PurpleFlowWeb.MCPController`). It keeps nothing between messages. See
  [specs/270](specs/270_mcp_files.md).

  It speaks both generations of [MCP](https://modelcontextprotocol.io/specification/2026-07-28):

  - **Newer** (`2026-07-28`): every request names its version in
    `params._meta`, and the HTTP headers must repeat the version, the
    method, and a tool call's name.
  - **Older** (`2025-06-18`, `2025-11-25`): a client opens with
    `initialize`; no session is kept.

  The only capability is `tools`, from `PurpleFlowWeb.MCP.Tools`.
  """

  alias PurpleFlowWeb.MCP.Tools

  @modern ["2026-07-28"]
  @legacy ["2025-11-25", "2025-06-18"]
  @version_key "io.modelcontextprotocol/protocolVersion"
  # How long a client may cache the tool list: it only changes with the app.
  @ttl_ms 3_600_000

  @doc """
  Answers `message` (the decoded body). `headers` holds the request's
  `mcp-protocol-version`, `mcp-method`, and `mcp-name` headers, by those
  names, when sent. Returns `{http_status, body}`, where body is the JSON
  answer as a map, or nil for a notification.
  """
  def handle(%{"jsonrpc" => "2.0", "method" => method} = message, headers)
      when is_binary(method) do
    params = if is_map(message["params"]), do: message["params"], else: %{}

    cond do
      not Map.has_key?(message, "id") -> {202, nil}
      modern?(params) -> modern(message["id"], method, params, headers)
      true -> legacy(message["id"], method, params)
    end
  end

  def handle(_message, _headers),
    do: {400, error(nil, -32600, "Invalid request: not a JSON-RPC 2.0 message")}

  defp modern?(params), do: is_binary(get_in(params, ["_meta", @version_key]))

  # Newer generation

  defp modern(id, method, params, headers) do
    version = params["_meta"][@version_key]

    cond do
      version not in @modern ->
        {400,
         error(id, -32022, "Unsupported protocol version", %{
           "supported" => supported(),
           "requested" => version
         })}

      mismatch = header_mismatch(version, method, params, headers) ->
        {400, error(id, -32020, "Header mismatch: " <> mismatch)}

      true ->
        case call(method, params) do
          {:ok, result} -> {200, ok(id, complete(method, result))}
          {:error, :unknown_method} -> {404, method_not_found(id, method)}
          {:error, code, why} -> {200, error(id, code, why)}
        end
    end
  end

  defp header_mismatch(version, method, params, headers) do
    cond do
      headers["mcp-protocol-version"] != version ->
        "MCP-Protocol-Version must be #{version}"

      headers["mcp-method"] != method ->
        "Mcp-Method must be #{method}"

      method == "tools/call" and decode_header(headers["mcp-name"]) != params["name"] ->
        "Mcp-Name must be the tool's name"

      true ->
        nil
    end
  end

  # A header value that isn't plain ASCII is sent as =?base64?...?=.
  defp decode_header("=?base64?" <> rest) do
    with true <- String.ends_with?(rest, "?="),
         {:ok, value} <- rest |> String.trim_trailing("?=") |> Base.decode64() do
      value
    else
      _ -> nil
    end
  end

  defp decode_header(value), do: value

  defp complete(method, result) do
    result =
      Map.merge(result, %{
        "resultType" => "complete",
        "_meta" => %{"io.modelcontextprotocol/serverInfo" => server_info()}
      })

    if method in ["server/discover", "tools/list"],
      do: Map.merge(result, %{"ttlMs" => @ttl_ms, "cacheScope" => "private"}),
      else: result
  end

  # Older generation

  defp legacy(id, "initialize", params) do
    version =
      if params["protocolVersion"] in @legacy, do: params["protocolVersion"], else: hd(@legacy)

    {200,
     ok(id, %{
       "protocolVersion" => version,
       "capabilities" => capabilities(),
       "serverInfo" => server_info(),
       "instructions" => instructions()
     })}
  end

  defp legacy(id, "ping", _params), do: {200, ok(id, %{})}

  defp legacy(id, method, params) do
    case call(method, params) do
      {:ok, result} -> {200, ok(id, result)}
      {:error, :unknown_method} -> {200, method_not_found(id, method)}
      {:error, code, why} -> {200, error(id, code, why)}
    end
  end

  # Both generations

  defp call("server/discover", _params) do
    {:ok,
     %{
       "supportedVersions" => supported(),
       "capabilities" => capabilities(),
       "instructions" => instructions()
     }}
  end

  defp call("tools/list", _params), do: {:ok, %{"tools" => Tools.list()}}

  defp call("tools/call", %{"name" => name} = params) when is_binary(name) do
    arguments = if is_map(params["arguments"]), do: params["arguments"], else: %{}

    case Tools.call(name, arguments) do
      {:ok, result} ->
        {:ok, result}

      {:error, :unknown_tool} ->
        {:error, -32602, "Unknown tool: #{name}"}

      {:error, {:invalid_arguments, why}} ->
        {:error, -32602, "Invalid arguments for #{name}: #{why}"}
    end
  end

  defp call("tools/call", _params), do: {:error, -32602, "tools/call needs a tool name"}
  defp call(_method, _params), do: {:error, :unknown_method}

  defp supported, do: @modern ++ @legacy
  defp capabilities, do: %{"tools" => %{}}

  defp server_info,
    do: %{"name" => "PurpleFlow", "version" => to_string(Application.spec(:purple_flow, :vsn))}

  defp instructions do
    "The workflows folder of this PurpleFlow, through its files service. " <>
      "How workflows are written is at #{PurpleFlowWeb.Endpoint.url()}/agents."
  end

  defp ok(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp method_not_found(id, method), do: error(id, -32601, "Method not found: #{method}")

  defp error(id, code, message, data \\ nil) do
    error = %{"code" => code, "message" => message}
    error = if data, do: Map.put(error, "data", data), else: error
    %{"jsonrpc" => "2.0", "id" => id, "error" => error}
  end
end
