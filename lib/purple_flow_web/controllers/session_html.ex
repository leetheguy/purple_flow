defmodule PurpleFlowWeb.SessionHTML do
  @moduledoc "The sign-in page."

  use PurpleFlowWeb, :html

  def new(assigns) do
    ~H"""
    <main class="min-h-dvh grid place-items-center px-4 py-12 bg-base-200/60">
      <div class="w-full max-w-sm">
        <div class="mb-8 flex flex-col items-center gap-3 text-center">
          <span class="grid place-items-center size-12 rounded-2xl bg-violet-600 shadow-lg shadow-violet-600/30">
            <span class="size-4 rounded-full bg-white/90"></span>
          </span>
          <h1 class="text-2xl font-semibold tracking-tight">PurpleFlow</h1>
          <p class="text-sm text-base-content/60">Sign in to your workflows</p>
        </div>

        <.form
          for={@form}
          id="login-form"
          action={~p"/login"}
          method="post"
          class="rounded-2xl border border-base-300 bg-base-100 p-6 shadow-xl shadow-black/5 space-y-4"
        >
          <div
            :if={@error}
            id="login-error"
            role="alert"
            class="flex items-center gap-2 rounded-lg bg-red-500/10 px-3 py-2 text-sm text-red-700 dark:text-red-300"
          >
            <.icon name="hero-exclamation-circle-micro" class="size-4 shrink-0" />
            {@error}
          </div>

          <.input field={@form[:return_to]} type="hidden" id="login-return-to" />

          <.input
            field={@form[:username]}
            type="text"
            id="login-username"
            label="Username"
            autocomplete="username"
            autocapitalize="none"
            spellcheck="false"
            required
            autofocus={@form[:username].value == ""}
            class={field_class()}
          />

          <.input
            field={@form[:password]}
            type="password"
            id="login-password"
            label="Password"
            autocomplete="current-password"
            required
            autofocus={@form[:username].value != ""}
            class={field_class()}
          />

          <button
            type="submit"
            id="login-submit"
            class="w-full rounded-lg bg-violet-600 px-3 py-2.5 font-medium text-white shadow-sm shadow-violet-600/30 transition hover:bg-violet-500 active:scale-[0.99] cursor-pointer"
          >
            Sign in
          </button>
        </.form>
      </div>
    </main>
    """
  end

  defp field_class,
    do:
      "w-full rounded-lg border border-base-300 bg-base-100 px-3 py-2 outline-none transition " <>
        "focus:border-violet-500 focus:ring-4 focus:ring-violet-500/15"
end
