defmodule PurpleFlowWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use PurpleFlowWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  The app's frame: a collapsible sidebar on wide screens, a top bar with a
  menu on small ones, and the page beside it.

  ## Examples

      <Layouts.app flash={@flash} active={:workflows}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :active, :atom,
    default: nil,
    doc: "the nav item to highlight: :workflows, :files, :credentials"

  attr :full, :boolean,
    default: false,
    doc: "the page fills the space beside the nav, edge to edge"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-dvh md:flex">
      <header class="md:hidden sticky top-0 z-40 h-14 flex items-center justify-between gap-3 border-b border-base-300 bg-base-100/85 backdrop-blur px-4">
        <.brand />
        <div id="mobile-menu" phx-click-away={hide_mobile_nav()}>
          <button
            type="button"
            id="nav-toggle"
            aria-label="Menu"
            aria-controls="mobile-nav"
            class="grid place-items-center size-9 rounded-lg hover:bg-base-200 transition cursor-pointer"
            phx-click={toggle_mobile_nav()}
          >
            <.icon name="hero-bars-3" class="size-5 mobile-nav-open" />
            <.icon name="hero-x-mark" class="size-5 mobile-nav-close hidden" />
          </button>
          <nav
            id="mobile-nav"
            class="hidden absolute inset-x-3 top-full mt-2 rounded-xl border border-base-300 bg-base-100 p-2 shadow-xl shadow-black/10"
          >
            <.nav_links active={@active} id_prefix="mobile-nav" />
            <div class="mt-2 flex items-center justify-between gap-2 border-t border-base-300 px-1 pt-3 pb-1">
              <.theme_toggle />
              <.sign_out id="mobile-sign-out" />
            </div>
          </nav>
        </div>
      </header>

      <aside
        id="sidebar"
        class="hidden md:flex sticky top-0 h-dvh shrink-0 flex-col w-60 sidebar-collapsed:w-16 border-r border-base-300 bg-base-200/50 transition-[width] duration-200 ease-out"
      >
        <div class="h-14 flex items-center justify-between gap-2 px-4 sidebar-collapsed:px-0 sidebar-collapsed:justify-center">
          <span class="sidebar-collapsed:hidden"><.brand /></span>
          <button
            type="button"
            id="sidebar-toggle"
            aria-label="Collapse the menu"
            title="Collapse or expand the menu"
            class="grid place-items-center size-8 rounded-lg text-base-content/50 hover:text-base-content hover:bg-base-300/60 transition cursor-pointer"
            phx-click={JS.dispatch("pf:toggle-sidebar")}
          >
            <.icon
              name="hero-chevron-double-left-micro"
              class="size-4 transition-transform duration-200 sidebar-collapsed:rotate-180"
            />
          </button>
        </div>

        <nav class="flex-1 px-3 sidebar-collapsed:px-2 py-2">
          <.nav_links active={@active} id_prefix="nav" />
        </nav>

        <div class="px-3 sidebar-collapsed:px-2 py-4 space-y-3 border-t border-base-300">
          <div class="sidebar-collapsed:hidden"><.theme_toggle /></div>
          <.sign_out id="sign-out" />
        </div>
      </aside>

      <main class={[
        "flex-1 min-w-0",
        if(@full, do: "flex flex-col h-[calc(100dvh-3.5rem)] md:h-dvh", else: "px-4 py-8 sm:px-8")
      ]}>
        <div :if={!@full} class="mx-auto max-w-5xl space-y-6">
          {render_slot(@inner_block)}
        </div>
        <%= if @full do %>
          {render_slot(@inner_block)}
        <% end %>
      </main>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  defp brand(assigns) do
    ~H"""
    <.link navigate={~p"/"} class="flex items-center gap-2 font-semibold tracking-tight">
      <span class="grid place-items-center size-6 rounded-lg bg-violet-600 shadow-sm shadow-violet-600/30">
        <span class="size-2 rounded-full bg-white/90"></span>
      </span>
      PurpleFlow
    </.link>
    """
  end

  attr :active, :atom, required: true
  attr :id_prefix, :string, required: true

  defp nav_links(assigns) do
    assigns =
      assign(assigns, :items, [
        {:workflows, "Workflows", ~p"/", "hero-bolt"},
        {:files, "Files", ~p"/files", "hero-folder"},
        {:credentials, "Credentials", ~p"/credentials", "hero-key"}
      ])

    ~H"""
    <ul class="space-y-1">
      <li :for={{key, label, path, icon} <- @items}>
        <.link
          navigate={path}
          id={"#{@id_prefix}-#{key}"}
          title={label}
          aria-current={if(@active == key, do: "page")}
          class={[
            "group flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium transition",
            "sidebar-collapsed:justify-center sidebar-collapsed:px-0",
            if(@active == key,
              do: "bg-violet-600/10 text-violet-700 dark:bg-violet-500/15 dark:text-violet-300",
              else: "text-base-content/70 hover:bg-base-300/60 hover:text-base-content"
            )
          ]}
        >
          <.icon
            name={icon}
            class={[
              "size-5 shrink-0 transition",
              if(@active == key,
                do: "text-violet-600 dark:text-violet-400",
                else: "opacity-70 group-hover:opacity-100"
              )
            ]}
          />
          <span class="sidebar-collapsed:hidden">{label}</span>
        </.link>
      </li>
    </ul>
    """
  end

  attr :id, :string, required: true

  defp sign_out(assigns) do
    ~H"""
    <.link
      :if={PurpleFlowWeb.Auth.required?()}
      href={~p"/logout"}
      method="delete"
      id={@id}
      title="Sign out"
      class="flex items-center gap-3 rounded-lg px-3 py-2 text-sm text-base-content/60 hover:text-base-content hover:bg-base-300/60 transition sidebar-collapsed:justify-center sidebar-collapsed:px-0"
    >
      <.icon name="hero-arrow-right-start-on-rectangle" class="size-5 shrink-0 opacity-70" />
      <span class="sidebar-collapsed:hidden">Sign out</span>
    </.link>
    """
  end

  defp toggle_mobile_nav do
    JS.toggle(
      to: "#mobile-nav",
      in:
        {"transition ease-out duration-150", "opacity-0 -translate-y-1",
         "opacity-100 translate-y-0"},
      out:
        {"transition ease-in duration-100", "opacity-100 translate-y-0",
         "opacity-0 -translate-y-1"}
    )
    |> JS.toggle_class("hidden", to: "#nav-toggle .mobile-nav-open")
    |> JS.toggle_class("hidden", to: "#nav-toggle .mobile-nav-close")
  end

  defp hide_mobile_nav do
    JS.hide(
      to: "#mobile-nav",
      transition: {"transition ease-in duration-100", "opacity-100", "opacity-0"}
    )
    |> JS.remove_class("hidden", to: "#nav-toggle .mobile-nav-open")
    |> JS.add_class("hidden", to: "#nav-toggle .mobile-nav-close")
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
