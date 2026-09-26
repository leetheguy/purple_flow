defmodule PurpleFlowWeb.FilesLive do
  @moduledoc """
  `/files/...`: the workflows folder, through the files service (dufs),
  inside the app's frame. The page embeds dufs's own UI from `/fs/...`
  (`PurpleFlowWeb.Plugs.FilesProxy`), and keeps the address bar on the
  folder or file being shown, so it can be bookmarked and reloaded.
  """

  use PurpleFlowWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Files")
     |> assign(:available?, Application.get_env(:purple_flow, :files_url) != nil)}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    %URI{path: path, query: query} = URI.parse(uri)
    # The raw, still-encoded path under /files, trailing slash and all.
    rest = String.replace_prefix(path || "", "/files", "")
    rest = if rest == "", do: "/", else: rest
    {:noreply, assign(socket, :src, "/fs" <> rest <> if(query, do: "?" <> query, else: ""))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:files} full>
      <%= if @available? do %>
        <iframe
          id="files-frame"
          src={@src}
          title="Workflow files"
          phx-hook=".FilesFrame"
          phx-update="ignore"
          class="flex-1 w-full border-0 bg-base-100"
        ></iframe>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".FilesFrame">
          export default {
            mounted() {
              // Keep the address bar on whatever the frame is showing.
              this.el.addEventListener("load", () => {
                let loc
                try { loc = this.el.contentWindow.location } catch (_) { return }
                if (!loc.pathname.startsWith("/fs")) return
                const here = "/files" + loc.pathname.slice(3) + loc.search
                if (here !== window.location.pathname + window.location.search) {
                  window.history.replaceState(window.history.state, "", here)
                }
              })
            }
          }
        </script>
      <% else %>
        <div id="files-unavailable" class="mx-auto max-w-xl px-4 py-16 text-center space-y-2">
          <.icon name="hero-folder" class="size-10 text-base-content/30" />
          <h1 class="text-lg font-semibold">The files service isn't running here</h1>
          <p class="text-sm text-base-content/60">
            On a Docker install, workflow files are edited on this page. Outside Docker, edit them in
            <code>{PurpleFlow.Workflows.dir()}/</code>
            directly; changes load on their own.
          </p>
        </div>
      <% end %>
    </Layouts.app>
    """
  end
end
