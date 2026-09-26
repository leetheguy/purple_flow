defmodule PurpleFlowWeb.CredentialsLive do
  @moduledoc """
  `/credentials`: create, edit, and archive credentials.

  The server never sends a stored `key` value to the browser, in any form,
  ever. A set credential's secret field shows as a fixed placeholder of dots
  until edit mode opens it as a real, empty input. See
  `specs/080_credentials.md`.
  """

  use PurpleFlowWeb, :live_view

  alias PurpleFlow.Credentials

  # An arbitrary constant, unrelated to any real value's length, so the UI
  # can't leak even that much about a set credential.
  @secret_placeholder String.duplicate("•", 10)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Credentials")
     |> assign(:search, "")
     |> assign(:editing_id, nil)
     |> assign(:secret_placeholder, @secret_placeholder)
     |> assign(:add_form, empty_form())
     |> assign(:edit_form, nil)
     |> load()}
  end

  @impl true
  def handle_event("search", %{"value" => query}, socket) do
    {:noreply, socket |> assign(:search, query) |> load()}
  end

  def handle_event("add", %{"credential" => params}, socket) do
    with {:ok, cred} <- Credentials.create(params["name"], params["description"] || ""),
         {:ok, _} <- Credentials.update(cred.id, %{key: params["key"]}) do
      {:noreply,
       socket
       |> assign(:add_form, empty_form())
       |> load()
       |> put_flash(:info, "Credential created")}
    else
      {:error, changeset} ->
        {:noreply, assign(socket, :add_form, to_form(changeset, as: :credential))}
    end
  end

  def handle_event("clear_add", _params, socket) do
    {:noreply, assign(socket, :add_form, empty_form())}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    id = String.to_integer(id)
    cred = Enum.find(socket.assigns.credentials, &(&1.id == id))

    form =
      to_form(%{"name" => cred.name, "description" => cred.description, "key" => ""},
        as: :credential
      )

    {:noreply, socket |> assign(:editing_id, id) |> assign(:edit_form, form)}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, socket |> assign(:editing_id, nil) |> assign(:edit_form, nil)}
  end

  def handle_event("save", %{"credential" => params}, socket) do
    id = socket.assigns.editing_id
    attrs = %{name: params["name"], description: params["description"] || "", key: params["key"]}

    case Credentials.update(id, attrs) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:editing_id, nil)
         |> assign(:edit_form, nil)
         |> load()
         |> put_flash(:info, "Credential updated")}

      {:error, changeset} ->
        {:noreply, assign(socket, :edit_form, to_form(changeset, as: :credential))}
    end
  end

  def handle_event("archive", %{"id" => id}, socket) do
    {:ok, _} = Credentials.archive(String.to_integer(id))
    {:noreply, socket |> load() |> put_flash(:info, "Credential archived")}
  end

  defp load(socket) do
    query = String.downcase(socket.assigns.search)

    credentials =
      Credentials.list()
      |> Enum.filter(fn c ->
        query == "" or String.contains?(String.downcase(c.name), query) or
          String.contains?(String.downcase(c.description), query)
      end)

    assign(socket, :credentials, credentials)
  end

  defp empty_form, do: to_form(%{"name" => "", "description" => "", "key" => ""}, as: :credential)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex items-center justify-between">
        <h1 class="text-xl font-semibold">Credentials</h1>
      </div>

      <input
        type="text"
        placeholder="Search by name or description..."
        value={@search}
        phx-keyup="search"
        phx-debounce="150"
        name="q"
        id="credentials-search"
        class="w-full font-mono text-sm rounded-md border border-base-300 bg-base-100 px-3 py-2"
      />

      <div id="credentials" class="rounded-lg border border-base-300 divide-y divide-base-300">
        <.form
          for={@add_form}
          id="add-credential-form"
          phx-submit="add"
          class="grid grid-cols-[1fr_1fr_1fr_auto] gap-2 items-center p-3"
        >
          <input
            type="text"
            name="credential[name]"
            value={@add_form[:name].value}
            placeholder="Name"
            class="font-mono text-sm rounded-md border border-base-300 bg-base-100 px-2 py-1.5"
          />
          <input
            type="text"
            name="credential[description]"
            value={@add_form[:description].value}
            placeholder="Description"
            class="text-sm rounded-md border border-base-300 bg-base-100 px-2 py-1.5"
          />
          <input
            type="text"
            name="credential[key]"
            value={@add_form[:key].value}
            placeholder="Value"
            class="font-mono text-sm rounded-md border border-base-300 bg-base-100 px-2 py-1.5"
          />
          <div class="flex gap-2">
            <button
              type="submit"
              class="px-3 py-1.5 rounded-md bg-violet-600 text-white text-sm hover:bg-violet-500 transition"
            >
              Save
            </button>
            <button
              type="button"
              phx-click="clear_add"
              class="px-3 py-1.5 rounded-md border border-base-300 text-sm hover:bg-base-200 transition"
            >
              Clear
            </button>
          </div>
        </.form>

        <p :if={@credentials == []} class="p-4 text-base-content/60 text-sm">
          No credentials yet. Add one above.
        </p>

        <div :for={cred <- @credentials} id={"credential-#{cred.id}"} class="p-3">
          <.form
            :if={@editing_id == cred.id}
            for={@edit_form}
            id={"edit-credential-form-#{cred.id}"}
            phx-submit="save"
            class="grid grid-cols-[1fr_1fr_1fr_auto] gap-2 items-center"
          >
            <input
              type="text"
              name="credential[name]"
              value={@edit_form[:name].value}
              class="font-mono text-sm rounded-md border border-base-300 bg-base-100 px-2 py-1.5"
            />
            <input
              type="text"
              name="credential[description]"
              value={@edit_form[:description].value}
              class="text-sm rounded-md border border-base-300 bg-base-100 px-2 py-1.5"
            />
            <input
              type="text"
              name="credential[key]"
              value=""
              placeholder={if cred.set, do: "Leave blank to keep current value", else: "Value"}
              class="font-mono text-sm rounded-md border border-base-300 bg-base-100 px-2 py-1.5"
            />
            <div class="flex gap-2">
              <button
                type="submit"
                class="px-3 py-1.5 rounded-md bg-violet-600 text-white text-sm hover:bg-violet-500 transition"
              >
                Save
              </button>
              <button
                type="button"
                phx-click="cancel_edit"
                class="px-3 py-1.5 rounded-md border border-base-300 text-sm hover:bg-base-200 transition"
              >
                Cancel
              </button>
            </div>
          </.form>

          <div
            :if={@editing_id != cred.id}
            class="grid grid-cols-[1fr_1fr_1fr_auto] gap-2 items-center"
          >
            <span
              id={"credential-name-#{cred.id}"}
              class="font-mono text-sm cursor-pointer inline-flex items-center gap-1.5"
              phx-hook=".CopyToClipboard"
              data-copy-text={cred.name}
              title="Click to copy"
            >
              {cred.name}
              <.icon name="hero-clipboard-micro" class="size-3.5 opacity-40 copy-icon" />
              <.icon
                name="hero-check-micro"
                class="size-3.5 text-emerald-500 opacity-0 transition-opacity copy-flash-icon"
              />
              <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyToClipboard">
                export default {
                  mounted() {
                    this.el.addEventListener("click", () => {
                      const text = this.el.dataset.copyText
                      navigator.clipboard.writeText(text).then(() => {
                        const flash = this.el.querySelector(".copy-flash-icon")
                        const icon = this.el.querySelector(".copy-icon")
                        if (!flash) return
                        icon?.classList.add("opacity-0")
                        flash.classList.remove("opacity-0")
                        clearTimeout(this._copyTimeout)
                        this._copyTimeout = setTimeout(() => {
                          flash.classList.add("opacity-0")
                          icon?.classList.remove("opacity-0")
                        }, 1200)
                      })
                    })
                  }
                }
              </script>
            </span>
            <span class="text-sm text-base-content/70">{cred.description}</span>
            <span class="font-mono text-sm text-base-content/50">
              {if cred.set, do: @secret_placeholder, else: "—"}
            </span>
            <div class="flex gap-2">
              <button
                phx-click="edit"
                phx-value-id={cred.id}
                class="p-1.5 rounded-md border border-base-300 hover:bg-base-200 transition"
                title="Edit"
              >
                <.icon name="hero-pencil-micro" class="size-4" />
              </button>
              <button
                phx-click="archive"
                phx-value-id={cred.id}
                class="p-1.5 rounded-md border border-base-300 hover:bg-base-200 transition"
                title="Archive"
              >
                <.icon name="hero-trash-micro" class="size-4" />
              </button>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
