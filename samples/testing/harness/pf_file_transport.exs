# Spec 260's release check: moves a file through the HTTP node's file
# options in a running app, and checks the run files folder is empty after.
#
#   mix run --no-start samples/testing/harness/pf_file_transport.exs
#
# Run it from a checkout, against the app as Docker runs it
# (`docker compose up -d --build`). It copies samples/testing/file_transport
# into the workflows folder, waits for the app to load it, sends a random
# file, checks the answer, and deletes the copies however it ends.
#
# Settings (environment):
#   PF_PORT         the app's port (default: PORT from .env, else 4000)
#   WORKFLOWS_PATH  the workflows folder (default ./workflows, as in compose)
#   PF_CONTAINER    the app's container (default purple_flow)
#
# Postgres and SSH need credentials set by a person, so they aren't here;
# their tests run against a real Postgres and SSH server (`mix test`).
{:ok, _} = Application.ensure_all_started(:req)

dot_env =
  case File.read(".env") do
    {:ok, text} -> Regex.run(~r/^PORT=(\d+)/m, text, capture: :all_but_first)
    _ -> nil
  end

port = System.get_env("PF_PORT") || (dot_env && hd(dot_env)) || "4000"
base = "http://localhost:#{port}"
workflows = System.get_env("WORKFLOWS_PATH", "workflows")
container = System.get_env("PF_CONTAINER", "purple_flow")
copies = for name <- ~w(check echo), do: {name, Path.join(workflows, "zz_file_transport_#{name}")}

defmodule Check do
  def pass(what), do: IO.puts("  PASS  #{what}")

  def fail(what, got) do
    IO.puts("  FAIL  #{what}\n        got: #{inspect(got, limit: 20)}")
    :failed
  end

  def expect(what, true, _got), do: pass(what)
  def expect(what, _false, got), do: fail(what, got)

  # The app reloads workflows about two seconds after a change.
  def wait_for(url, deadline) do
    case Req.post(url, retry: false, receive_timeout: 5_000) do
      {:ok, %{status: status}} when status != 404 ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          :timeout
        else
          Process.sleep(500)
          wait_for(url, deadline)
        end
    end
  end
end

failed? =
  try do
    for {name, dest} <- copies, do: File.cp_r!("samples/testing/file_transport/#{name}", dest)
    IO.puts("Copied the check workflows into #{workflows}; waiting for #{base} to load them…")

    if Check.wait_for(
         "#{base}/hooks/file-transport-echo",
         System.monotonic_time(:millisecond) + 20_000
       ) ==
         :timeout do
      raise "the app at #{base} didn't load the workflows in 20 seconds (is it running?)"
    end

    bytes = :crypto.strong_rand_bytes(300_000)
    IO.puts("Sending a 300,000-byte file…")

    {:ok, resp} =
      Req.post("#{base}/hooks/file-transport-check",
        retry: false,
        receive_timeout: 60_000,
        form_multipart: [
          echo_url: "http://localhost:#{port}/hooks/file-transport-echo",
          health_url: "http://localhost:#{port}/health",
          doc: {bytes, filename: "sample.pdf", content_type: "application/pdf"}
        ]
      )

    report = resp.body

    results = [
      Check.expect("the check workflow ran (200)", resp.status == 200, {resp.status, report}),
      Check.expect(
        "form: the file went out as a part, with its name, type, and size",
        match?(
          %{
            "form" => %{
              "doc" => %{"name" => "sample.pdf", "type" => "application/pdf", "size" => 300_000}
            }
          },
          report
        ),
        report["form"]
      ),
      Check.expect(
        "form: the text field went beside it",
        get_in(report, ["form", "note"]) == "hi",
        report["form"]
      ),
      Check.expect(
        "body_file: the file went out as the body, with its type and length",
        report["body"] == %{"content-type" => "application/pdf", "content-length" => "300000"},
        report["body"]
      ),
      Check.expect(
        "response_file: a download came back in as a file",
        match?(%{"download" => %{"name" => "health", "size" => size}} when size > 0, report),
        report["download"]
      )
    ]

    {listing, status} =
      System.cmd("docker", ["exec", container, "ls", "-A", "/app/run_files"],
        stderr_to_stdout: true
      )

    results =
      results ++
        [
          Check.expect(
            "the run files folder is empty once the runs end",
            status == 0 and String.trim(listing) == "",
            listing
          )
        ]

    :failed in results
  after
    for {_name, dest} <- copies, do: File.rm_rf!(dest)
    IO.puts("Removed the check workflows from #{workflows}")
  end

# Only after cleaning up: System.halt/1 inside the try would skip `after`.
if failed? do
  IO.puts("File transport check FAILED")
  System.halt(1)
else
  IO.puts("File transport check passed")
end
