# A tool gets the agent's params as its body.
params = input["body"]
if params["fail"], do: {:error, "the tool was told to fail"}, else: "result #{params["n"]}"
