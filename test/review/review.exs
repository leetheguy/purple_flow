# Runs an independent review. Use test/review/review.sh, which starts this
# without starting the app. See test/review/README.md.
Code.require_file("review_lib.exs", __DIR__)
{:ok, _} = Application.ensure_all_started(:req)

case PurpleFlow.Review.main(System.argv()) do
  :ok ->
    :ok

  {:error, message} ->
    IO.puts(:stderr, message)
    System.halt(1)
end
