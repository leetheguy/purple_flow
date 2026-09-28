defmodule PurpleFlowWeb.MultipartParser do
  @moduledoc """
  Plug's multipart parser (file uploads), with the size limit taken from
  the webhook being called: its `max_upload` in bytes (default 100 MB,
  0 = no limit). Anything bigger gets `413`. Other paths keep Plug's
  default of 8 MB.
  """

  @behaviour Plug.Parsers

  @multipart Plug.Parsers.MULTIPART
  @default 8_000_000
  # "No limit": more than any disk holds.
  @unlimited 4_611_686_018_427_387_904

  @impl true
  def init(opts), do: opts

  @impl true
  def parse(conn, "multipart", subtype, headers, opts) do
    opts = @multipart.init([length: limit(conn)] ++ opts)
    @multipart.parse(conn, "multipart", subtype, headers, opts)
  end

  def parse(conn, _type, _subtype, _headers, _opts), do: {:next, conn}

  defp limit(%{path_info: ["hooks" | path]}) do
    case PurpleFlow.Workflows.find_webhook(Enum.join(path, "/")) do
      %{max_upload: 0} -> @unlimited
      %{max_upload: n} -> n
      nil -> @default
    end
  end

  defp limit(_conn), do: @default
end
