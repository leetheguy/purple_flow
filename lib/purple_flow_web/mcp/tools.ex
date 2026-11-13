defmodule PurpleFlowWeb.MCP.Tools do
  @moduledoc """
  The MCP tools: the files service's API, one dufs request per tool, over
  the workflows folder. `PurpleFlowWeb.MCP.Server` lists them and calls
  them. See [specs/270](specs/270_mcp_files.md).

  Each request goes through `PurpleFlowWeb.Plugs.FilesProxy.dufs_request/1`,
  the same way `/fs/` reaches dufs. A tool's `path` is relative to the
  workflows folder and can't climb out of it.

  `call/2` returns `{:ok, result}` with an MCP tool result
  (`%{"content" => [...], "isError" => ...}`), including when dufs said no:
  that's a tool error, for the agent to read. `{:error, ...}` is a bad call
  (no such tool, or arguments that don't fit), which MCP answers as a
  JSON-RPC error instead.
  """

  alias PurpleFlowWeb.Plugs.FilesProxy

  @path %{
    "type" => "string",
    "description" =>
      "Path in the workflows folder, like `hello/workflow.toml`. Empty or `/` is the top."
  }
  @content %{
    "type" => "string",
    "description" => "The file's content: text, or base64 when `encoding` is `base64`."
  }
  @encoding %{
    "type" => "string",
    "enum" => ["text", "base64"],
    "description" => "How `content` is written. Defaults to `text`."
  }
  @destination %{
    "type" => "string",
    "description" => "Where it goes, a path in the workflows folder."
  }

  # name, the dufs request, the description, and the arguments past `path`.
  @tools [
    {"list", "GET path/?json",
     "Lists a folder: each entry's name, type (file or dir), size in bytes, and modified time. Start with an empty path. How workflows are written is at GET /agents on this site.",
     %{}, []},
    {"search", "GET path/?q=QUERY&json",
     "Finds files and folders whose name contains `query`, anywhere under the folder at `path`. Paths come back relative to that folder.",
     %{"query" => %{"type" => "string", "description" => "Text the name contains."}}, ["query"]},
    {"read", "GET path",
     "Reads a file. Text comes back as text; anything else as base64. Give `offset` and `length` (bytes) to read a large file a piece at a time; without them it reads the whole file.",
     %{
       "offset" => %{"type" => "integer", "minimum" => 0, "description" => "First byte to read."},
       "length" => %{
         "type" => "integer",
         "minimum" => 1,
         "description" => "How many bytes to read."
       }
     }, []},
    {"stat", "HEAD path",
     "Whether something is at `path`, and for something that is: its type (file or dir), and for a file its size, modified time, and etag.",
     %{}, []},
    {"hash", "GET path?hash", "A file's SHA-256, in hex.", %{}, []},
    {"write", "PUT path",
     "Writes a file, replacing one that's there and making any folders that are missing. A saved workflow is live within a couple of seconds.",
     %{"content" => @content, "encoding" => @encoding}, ["content"]},
    {"append", "PATCH path, X-Update-Range: append",
     "Adds `content` to the end of a file that exists.",
     %{"content" => @content, "encoding" => @encoding}, ["content"]},
    {"mkdir", "MKCOL path", "Makes a folder.", %{}, []},
    {"copy", "COPY path, Destination", "Copies a file or folder to `destination`.",
     %{"destination" => @destination}, ["destination"]},
    {"move", "MOVE path, Destination", "Moves or renames a file or folder to `destination`.",
     %{"destination" => @destination}, ["destination"]},
    {"delete", "DELETE path", "Deletes a file, or a folder with everything in it.", %{}, []}
  ]

  @names for {name, _, _, _, _} <- @tools, do: name

  @doc "Every tool's MCP definition (`name`, `description`, `inputSchema`), always in the same order."
  def list do
    for {name, request, description, properties, required} <- @tools do
      %{
        "name" => name,
        "description" => description <> " (dufs: #{request})",
        "inputSchema" => %{
          "type" => "object",
          "properties" => Map.put(properties, "path", @path),
          "required" => ["path" | required],
          "additionalProperties" => false
        }
      }
    end
  end

  @doc """
  Runs the tool `name` with `args` (a map from the call's JSON). Returns
  `{:ok, result}`, an MCP tool result, or `{:error, :unknown_tool}` or
  `{:error, {:invalid_arguments, why}}`.
  """
  def call(name, args) when name in @names and is_map(args) do
    with {:ok, args} <- check(name, args) do
      {:ok, run(name, args)}
    end
  end

  def call(_name, _args), do: {:error, :unknown_tool}

  # Arguments

  defp check(name, args) do
    {_, _, _, properties, required} = List.keyfind(@tools, name, 0)

    with :ok <- strings(args, ["path" | Map.keys(properties) -- ["offset", "length"]]),
         :ok <- present(args, required),
         :ok <- range(args),
         {:ok, args} <- decode(args) do
      {:ok, args}
    end
  end

  defp strings(args, keys) do
    case Enum.find(keys, &(Map.has_key?(args, &1) and not is_binary(args[&1]))) do
      nil -> if is_binary(args["path"]), do: :ok, else: bad("path is required, as text")
      key -> bad("#{key} must be text")
    end
  end

  defp present(args, keys) do
    case Enum.find(keys, &(not Map.has_key?(args, &1))) do
      nil -> :ok
      key -> bad("#{key} is required")
    end
  end

  defp range(%{"offset" => offset, "length" => length})
       when is_integer(offset) and offset >= 0 and is_integer(length) and length >= 1,
       do: :ok

  defp range(args) do
    if Map.has_key?(args, "offset") or Map.has_key?(args, "length"),
      do: bad("offset and length go together: offset 0 or more, length 1 or more"),
      else: :ok
  end

  defp decode(%{"encoding" => "base64", "content" => content} = args) do
    case Base.decode64(content) do
      {:ok, bytes} -> {:ok, %{args | "content" => bytes}}
      :error -> bad("content isn't valid base64")
    end
  end

  defp decode(%{"encoding" => encoding}) when encoding != "text",
    do: bad("encoding is text or base64")

  defp decode(args), do: {:ok, args}

  defp bad(why), do: {:error, {:invalid_arguments, why}}

  # Requests

  defp run(name, %{"path" => path} = args) do
    with {:ok, url} <- url(path),
         {:ok, request} <- request(name, url, args),
         {:ok, response} <- send_request(request) do
      answer(name, path, response)
    else
      {:error, why} -> failed(why)
    end
  end

  defp request("list", url, _), do: {:ok, [method: :get, url: folder(url) <> "?json"]}

  defp request("search", url, %{"query" => query}),
    do:
      {:ok,
       [method: :get, url: folder(url) <> "?" <> URI.encode_query(%{"q" => query, "json" => ""})]}

  defp request("read", url, %{"offset" => offset, "length" => length}),
    do:
      {:ok,
       [method: :get, url: url, headers: [{"range", "bytes=#{offset}-#{offset + length - 1}"}]]}

  defp request("read", url, _), do: {:ok, [method: :get, url: url]}
  defp request("stat", url, _), do: {:ok, [method: :head, url: url]}
  defp request("hash", url, _), do: {:ok, [method: :get, url: url <> "?hash"]}
  defp request("write", url, args), do: {:ok, [method: :put, url: url, body: args["content"]]}

  defp request("append", url, args),
    do:
      {:ok,
       [method: :patch, url: url, body: args["content"], headers: [{"x-update-range", "append"}]]}

  defp request("mkdir", url, _), do: {:ok, [method: "MKCOL", url: url]}
  defp request("copy", url, args), do: moved("COPY", url, args)
  defp request("move", url, args), do: moved("MOVE", url, args)
  defp request("delete", url, _), do: {:ok, [method: :delete, url: url]}

  defp moved(method, url, %{"destination" => destination}) do
    with {:ok, to} <- url(destination) do
      {:ok, [method: method, url: url, headers: [{"destination", FilesProxy.files_url() <> to}]]}
    end
  end

  defp folder("/fs/"), do: "/fs/"
  defp folder(url), do: url <> "/"

  # Each segment is encoded on its own, so `?`, `#`, and `%` stay part of a
  # name. `..` and `.` are refused rather than resolved: dufs keeps paths in
  # its folder too, but a path like that never needs to reach it.
  defp url(path) do
    segments = String.split(path, "/", trim: true)

    cond do
      String.contains?(path, ["\\", <<0>>]) or Enum.any?(segments, &(&1 in [".", ".."])) ->
        {:error, "can't use #{inspect(path)}: a path can't have `..`, `.`, `\\`, or NUL in it"}

      true ->
        {:ok,
         "/fs/" <>
           Enum.map_join(segments, "/", &URI.encode(&1, fn c -> URI.char_unreserved?(c) end))}
    end
  end

  defp send_request(request) do
    if FilesProxy.files_url() do
      case FilesProxy.dufs_request(request) do
        {:ok, response} ->
          {:ok, response}

        {:error, exception} ->
          {:error, "couldn't reach the files service: #{Exception.message(exception)}"}
      end
    else
      {:error, "the files service isn't set up on this PurpleFlow"}
    end
  end

  # Answers

  defp answer("stat", _path, %{status: 404}), do: done(%{"exists" => false})

  defp answer(name, path, %{status: status} = response) when status in 200..299,
    do: success(name, path, response)

  defp answer(_name, path, %{status: 404}), do: failed("nothing at #{path}")

  defp answer(_name, _path, %{status: status, body: body}),
    do: failed("the files service answered #{status}: #{String.slice(to_string(body), 0, 500)}")

  defp success(name, _path, %{body: body}) when name in ["list", "search"] do
    %{"paths" => paths} = Jason.decode!(body)
    done(%{"entries" => Enum.map(paths, &entry/1)})
  end

  defp success("read", _path, %{body: body}) do
    if String.valid?(body),
      do: text(body),
      else: done(%{"encoding" => "base64", "content" => Base.encode64(body)})
  end

  defp success("stat", _path, response) do
    case header(response, "etag") do
      nil ->
        done(%{"exists" => true, "type" => "dir"})

      etag ->
        done(%{
          "exists" => true,
          "type" => "file",
          "size" => String.to_integer(header(response, "content-length") || "0"),
          "mtime" => http_date(header(response, "last-modified")),
          "etag" => etag
        })
    end
  end

  defp success("hash", _path, %{body: body}), do: done(%{"sha256" => String.trim(body)})
  defp success(_name, path, _response), do: text("done: #{path}")

  defp entry(%{"path_type" => type, "name" => name, "size" => size, "mtime" => mtime}) do
    %{
      "name" => name,
      "type" => if(String.ends_with?(type, "Dir"), do: "dir", else: "file"),
      "size" => size,
      "mtime" => mtime |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
    }
  end

  defp header(%{headers: headers}, name) do
    case headers[name] do
      [value | _] -> value
      _ -> nil
    end
  end

  # dufs's Last-Modified, like "Fri, 13 Nov 2026 03:32:20 GMT", as ISO 8601.
  defp http_date(nil), do: nil

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  defp http_date(value) do
    with [_, day, month, year, time] <-
           Regex.run(~r/^\w+, (\d\d) (\w+) (\d{4}) (\d\d:\d\d:\d\d) GMT$/, value),
         index when index != nil <- Enum.find_index(@months, &(&1 == month)),
         {:ok, date} <- Date.new(String.to_integer(year), index + 1, String.to_integer(day)),
         {:ok, time} <- Time.from_iso8601(time) do
      DateTime.new!(date, time) |> DateTime.to_iso8601()
    else
      # Something else: passed on as dufs sent it.
      _ -> value
    end
  end

  defp done(data), do: result(Jason.encode!(data), false) |> Map.put("structuredContent", data)
  defp text(text), do: result(text, false)
  defp failed(why), do: result(redact(why), true)

  defp result(text, error?),
    do: %{"content" => [%{"type" => "text", "text" => text}], "isError" => error?}

  defp redact(text),
    do: Enum.reduce(FilesProxy.dufs_secrets(), text, &String.replace(&2, &1, "[redacted]"))
end
