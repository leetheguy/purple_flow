defmodule PurpleFlow.Nodes.Http do
  @moduledoc """
  Makes an HTTP request with `Req`.

      module = "PurpleFlow.Nodes.Http"

      [config]
      method = "POST"                       # default "GET"
      url = "https://api.example.com/items"
      headers = { authorization = "Bearer {{ env.API_TOKEN }}" }
      query = { page = 1 }                  # optional
      body = { name = "{{ input.name }}" }  # optional; maps/lists are sent as JSON

  Output is the response body (decoded if it's JSON). A non-2xx response is
  an error. No retries: a failure fails loud.
  """

  @behaviour PurpleFlow.Node

  @impl true
  def execute(_input, config) do
    options =
      [
        method:
          config |> Map.get("method", "GET") |> String.downcase() |> String.to_existing_atom(),
        url: Map.fetch!(config, "url"),
        headers: Map.get(config, "headers", %{}),
        params: Map.get(config, "query", %{}),
        retry: false
      ] ++ body(config["body"]) ++ Application.get_env(:purple_flow, :http_req_options, [])

    case Req.request(options) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{preview(body)}"}

      {:error, error} ->
        {:error, "request failed: #{Exception.message(error)}"}
    end
  end

  defp body(nil), do: []
  defp body(body) when is_map(body) or is_list(body), do: [json: body]
  defp body(body), do: [body: to_string(body)]

  defp preview(body) when is_binary(body), do: String.slice(body, 0, 500)
  defp preview(body), do: body |> Jason.encode!() |> String.slice(0, 500)
end
