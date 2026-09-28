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
  alias PurpleFlow.Credentials.OAuth

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
     |> assign(:callback_url, PurpleFlowWeb.OAuthController.callback_url())
     |> assign(:show_urls, false)
     |> assign(:add_form, empty_form())
     |> assign(:edit_form, nil)
     |> load()}
  end

  @impl true
  def handle_event("search", %{"value" => query}, socket) do
    {:noreply, socket |> assign(:search, query) |> load()}
  end

  # An OAuth credential is saved, then connected: the browser goes to the
  # provider's "allow this?" page and comes back. See OAuthController.
  def handle_event("add", %{"credential" => %{"type" => "oauth"} = params}, socket) do
    attrs = %{
      type: "oauth",
      oauth: oauth_settings(params),
      client_secret: params["client_secret"]
    }

    case Credentials.create(params["name"], params["description"] || "", attrs) do
      {:ok, cred} ->
        {:noreply, redirect(socket, to: ~p"/credentials/#{cred.id}/connect")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:add_form, to_form(params, as: :credential))
         |> put_flash(:error, error_message(changeset))}
    end
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

  # Keeps the server's copy of the add row in step with what's typed, so
  # resetting it (Save, Clear) is a change the page actually applies, and
  # picking a type shows its fields.
  def handle_event("change_add", %{"credential" => params}, socket) do
    {:noreply, assign(socket, :add_form, to_form(params, as: :credential))}
  end

  def handle_event("clear_add", _params, socket) do
    {:noreply, socket |> assign(:add_form, empty_form()) |> assign(:show_urls, false)}
  end

  def handle_event("toggle_urls", _params, socket) do
    {:noreply, update(socket, :show_urls, &(!&1))}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    id = String.to_integer(id)
    cred = Enum.find(socket.assigns.credentials, &(&1.id == id))

    form =
      to_form(
        Map.merge(
          %{"name" => cred.name, "description" => cred.description, "key" => ""},
          if(cred.type == "oauth", do: Map.put(settings(cred), "client_secret", ""), else: %{})
        ),
        as: :credential
      )

    {:noreply, socket |> assign(:editing_id, id) |> assign(:edit_form, form)}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, socket |> assign(:editing_id, nil) |> assign(:edit_form, nil)}
  end

  def handle_event("save", %{"credential" => params}, socket) do
    id = socket.assigns.editing_id
    cred = Enum.find(socket.assigns.credentials, &(&1.id == id))
    attrs = %{name: params["name"], description: params["description"] || ""}

    attrs =
      if cred.type == "oauth",
        do:
          Map.merge(attrs, %{
            oauth: oauth_settings(params),
            client_secret: params["client_secret"]
          }),
        else: Map.put(attrs, :key, params["key"])

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

  defp empty_form do
    to_form(
      Map.merge(
        %{"type" => "text", "name" => "", "description" => "", "key" => ""},
        Map.merge(OAuth.defaults(), %{"client_id" => "", "client_secret" => "", "scopes" => ""})
      ),
      as: :credential
    )
  end

  # An OAuth credential's settings from the form. Blank addresses mean Google's.
  defp oauth_settings(params) do
    defaults = OAuth.defaults()

    Map.new(~w(client_id scopes auth_url token_url), fn field ->
      value = String.trim(params[field] || "")
      {field, if(value == "", do: defaults[field] || "", else: value)}
    end)
  end

  defp settings(cred), do: Map.merge(OAuth.defaults(), cred.oauth || %{})

  defp error_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _} -> message end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  # "connected", "not connected", or "needs reconnecting".
  defp oauth_state(%{oauth_error: error}) when is_binary(error), do: :broken
  defp oauth_state(%{set: false}), do: :unconnected
  defp oauth_state(_cred), do: :connected

  # One layout for the add row, edit rows, and list rows, so the columns
  # line up: type, name, description, value, buttons. Two columns on a phone.
  @row "grid grid-cols-2 md:grid-cols-[6.5rem_1fr_1fr_1fr_8.5rem] gap-2 items-center"
  @input "w-full min-w-0 text-sm rounded-md border border-base-300 bg-base-100 px-2 py-1.5"
  @button "px-3 py-1.5 rounded-md text-sm transition"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, row: @row, input: @input, button: @button)

    ~H"""
    <Layouts.app flash={@flash} active={:credentials}>
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
          phx-change="change_add"
          phx-submit="add"
          class={[@row, "p-3"]}
        >
          <select id="add-credential-type" name="credential[type]" class={@input}>
            <option value="text" selected={@add_form[:type].value != "oauth"}>Text</option>
            <option value="oauth" selected={@add_form[:type].value == "oauth"}>OAuth</option>
          </select>
          <input
            type="text"
            name="credential[name]"
            value={@add_form[:name].value}
            placeholder="Name"
            class={[@input, "font-mono"]}
          />
          <input
            type="text"
            name="credential[description]"
            value={@add_form[:description].value}
            placeholder="Description"
            class={@input}
          />
          <%= if @add_form[:type].value == "oauth" do %>
            <input
              type="text"
              name="credential[scopes]"
              value={@add_form[:scopes].value}
              placeholder="Scopes"
              title="Space-separated, like https://www.googleapis.com/auth/gmail.send"
              class={[@input, "font-mono"]}
            />
          <% else %>
            <input
              type="text"
              name="credential[key]"
              value={@add_form[:key].value}
              placeholder="Value"
              class={[@input, "font-mono"]}
            />
          <% end %>
          <div class="col-span-2 md:col-span-1 flex gap-2 justify-end">
            <button type="submit" class={[@button, "bg-violet-600 text-white hover:bg-violet-500"]}>
              Save
            </button>
            <button
              type="button"
              phx-click="clear_add"
              class={[@button, "border border-base-300 hover:bg-base-200"]}
            >
              Clear
            </button>
          </div>

          <.oauth_fields
            :if={@add_form[:type].value == "oauth"}
            id="add"
            form={@add_form}
            input={@input}
            callback_url={@callback_url}
            show_urls={@show_urls}
            secret_placeholder="Client secret"
          />
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
            class={@row}
          >
            <.type_badge type={cred.type} />
            <input
              type="text"
              name="credential[name]"
              value={@edit_form[:name].value}
              class={[@input, "font-mono"]}
            />
            <input
              type="text"
              name="credential[description]"
              value={@edit_form[:description].value}
              class={@input}
            />
            <%= if cred.type == "oauth" do %>
              <input
                type="text"
                name="credential[scopes]"
                value={@edit_form[:scopes].value}
                placeholder="Scopes"
                class={[@input, "font-mono"]}
              />
            <% else %>
              <input
                type="text"
                name="credential[key]"
                value=""
                placeholder={if cred.set, do: "Leave blank to keep current value", else: "Value"}
                class={[@input, "font-mono"]}
              />
            <% end %>
            <div class="col-span-2 md:col-span-1 flex gap-2 justify-end">
              <button type="submit" class={[@button, "bg-violet-600 text-white hover:bg-violet-500"]}>
                Save
              </button>
              <button
                type="button"
                phx-click="cancel_edit"
                class={[@button, "border border-base-300 hover:bg-base-200"]}
              >
                Cancel
              </button>
            </div>

            <.oauth_fields
              :if={cred.type == "oauth"}
              id={"edit-#{cred.id}"}
              form={@edit_form}
              input={@input}
              callback_url={@callback_url}
              show_urls={true}
              secret_placeholder="Client secret (blank keeps it)"
            />
          </.form>

          <div :if={@editing_id != cred.id} class={@row}>
            <.type_badge type={cred.type} />
            <span
              id={"credential-name-#{cred.id}"}
              class="font-mono text-sm cursor-pointer inline-flex items-center gap-1.5 min-w-0"
              phx-hook=".CopyToClipboard"
              data-copy-text={cred.name}
              title="Click to copy"
            >
              <span class="truncate">{cred.name}</span>
              <.icon name="hero-clipboard-micro" class="size-3.5 opacity-40 copy-icon shrink-0" />
              <.icon
                name="hero-check-micro"
                class="size-3.5 text-emerald-500 opacity-0 transition-opacity copy-flash-icon shrink-0"
              />
            </span>
            <span class="text-sm text-base-content/70 min-w-0 truncate">{cred.description}</span>
            <%= if cred.type == "oauth" do %>
              <span
                id={"credential-state-#{cred.id}"}
                class={[
                  "text-sm",
                  oauth_state(cred) == :connected && "text-emerald-600",
                  oauth_state(cred) != :connected && "text-red-600"
                ]}
                title={cred.oauth_error}
              >
                {case oauth_state(cred) do
                  :connected -> "connected"
                  :unconnected -> "not connected"
                  :broken -> "needs reconnecting"
                end}
              </span>
            <% else %>
              <span class="font-mono text-sm text-base-content/50">
                {if cred.set, do: @secret_placeholder, else: "—"}
              </span>
            <% end %>
            <div class="col-span-2 md:col-span-1 flex gap-2 justify-end">
              <.link
                :if={cred.type == "oauth"}
                id={"reconnect-#{cred.id}"}
                href={~p"/credentials/#{cred.id}/connect"}
                title="Reconnect"
                class={[
                  "p-1.5 rounded-md border transition",
                  oauth_state(cred) == :connected && "border-base-300 hover:bg-base-200",
                  oauth_state(cred) != :connected &&
                    "border-red-500 bg-red-500 text-white hover:bg-red-600"
                ]}
              >
                <.icon name="hero-arrow-path-micro" class="size-4" />
              </.link>
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
    </Layouts.app>
    """
  end

  attr :type, :string, required: true

  defp type_badge(assigns) do
    ~H"""
    <span class="text-xs uppercase tracking-wide text-base-content/50">
      {if @type == "oauth", do: "OAuth", else: "Text"}
    </span>
    """
  end

  # An OAuth credential's second row (client ID, secret, callback address)
  # and, when shown, a third (the provider's two addresses). Lines up under
  # name, description, and value.
  attr :id, :string, required: true
  attr :form, :any, required: true
  attr :input, :string, required: true
  attr :callback_url, :string, required: true
  attr :show_urls, :boolean, required: true
  attr :secret_placeholder, :string, required: true

  defp oauth_fields(assigns) do
    ~H"""
    <div class="hidden md:block"></div>
    <input
      type="text"
      name="credential[client_id]"
      value={@form[:client_id].value}
      placeholder="Client ID"
      class={[@input, "font-mono"]}
    />
    <input
      type="password"
      name="credential[client_secret]"
      value=""
      placeholder={@secret_placeholder}
      autocomplete="off"
      class={[@input, "font-mono"]}
    />
    <div class="col-span-2 flex items-center gap-2 text-xs text-base-content/60 min-w-0">
      <span
        id={"callback-url-#{@id}"}
        class="flex items-center gap-1 min-w-0 cursor-pointer hover:text-base-content transition"
        phx-hook=".CopyToClipboard"
        data-copy-text={@callback_url}
        title="Paste this into your OAuth client's redirect URIs. Click to copy."
      >
        <span class="relative size-3.5 shrink-0">
          <.icon name="hero-clipboard-micro" class="absolute inset-0 size-3.5 copy-icon" />
          <.icon
            name="hero-check-micro"
            class="absolute inset-0 size-3.5 text-emerald-500 opacity-0 transition-opacity copy-flash-icon"
          />
        </span>
        <span class="shrink-0">Redirect URI</span>
        <span class="font-mono truncate">{@callback_url}</span>
      </span>
      <button
        :if={not @show_urls}
        type="button"
        phx-click="toggle_urls"
        class="shrink-0 underline hover:text-base-content transition"
      >
        change provider
      </button>
    </div>
    <%= if @show_urls do %>
      <div class="hidden md:block"></div>
      <input
        type="text"
        name="credential[auth_url]"
        value={@form[:auth_url].value}
        placeholder="Authorize URL"
        class={[@input, "font-mono"]}
      />
      <input
        type="text"
        name="credential[token_url]"
        value={@form[:token_url].value}
        placeholder="Token URL"
        class={[@input, "font-mono"]}
      />
      <div class="col-span-2"></div>
    <% else %>
      <input type="hidden" name="credential[auth_url]" value={@form[:auth_url].value} />
      <input type="hidden" name="credential[token_url]" value={@form[:token_url].value} />
    <% end %>
    """
  end
end
