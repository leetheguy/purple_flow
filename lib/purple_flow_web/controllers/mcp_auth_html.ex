defmodule PurpleFlowWeb.MCPAuthHTML do
  @moduledoc """
  The pages of signing in an MCP app (`PurpleFlowWeb.MCPAuthController`):
  whether to allow it, and why a request was refused.
  """

  use PurpleFlowWeb, :html

  @doc "Asks whether to allow the app. The form carries the request back, with the answer."
  def consent(assigns) do
    ~H"""
    <.card>
      <h1 class="text-lg font-semibold tracking-tight">
        <span id="mcp-app-name">{@app.name}</span>
        wants to read and change the files in your workflows folder.
      </h1>
      <p class="text-sm text-base-content/70">
        It will be sent back to <strong id="mcp-redirect-host">{@app.redirect_host}</strong>.
      </p>

      <form id="mcp-consent" action={~p"/oauth/authorize"} method="post" class="flex gap-3 pt-2">
        <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
        <input :for={{name, value} <- @params} type="hidden" name={name} value={value} />
        <button
          type="submit"
          name="decision"
          value="allow"
          id="mcp-allow"
          class="flex-1 rounded-lg bg-violet-600 px-3 py-2.5 font-medium text-white shadow-sm shadow-violet-600/30 transition hover:bg-violet-500 active:scale-[0.99] cursor-pointer"
        >
          Allow
        </button>
        <button
          type="submit"
          name="decision"
          value="deny"
          id="mcp-deny"
          class="flex-1 rounded-lg border border-base-300 px-3 py-2.5 font-medium transition hover:bg-base-200 active:scale-[0.99] cursor-pointer"
        >
          Deny
        </button>
      </form>
    </.card>
    """
  end

  @doc "Says why a request to connect was refused."
  def refused(assigns) do
    ~H"""
    <.card>
      <h1 class="text-lg font-semibold tracking-tight">Can't connect this app</h1>
      <p id="mcp-refused" class="text-sm text-base-content/70">
        The request was refused: {@why}. Nothing was sent back to the app.
      </p>
    </.card>
    """
  end

  slot :inner_block, required: true

  defp card(assigns) do
    ~H"""
    <main class="min-h-dvh grid place-items-center px-4 py-12 bg-base-200/60">
      <div class="w-full max-w-md">
        <div class="mb-8 flex flex-col items-center gap-3 text-center">
          <span class="grid place-items-center size-12 rounded-2xl bg-violet-600 shadow-lg shadow-violet-600/30">
            <span class="size-4 rounded-full bg-white/90"></span>
          </span>
          <p class="text-2xl font-semibold tracking-tight">PurpleFlow</p>
        </div>
        <div class="rounded-2xl border border-base-300 bg-base-100 p-6 shadow-xl shadow-black/5 space-y-3">
          {render_slot(@inner_block)}
        </div>
      </div>
    </main>
    """
  end
end
