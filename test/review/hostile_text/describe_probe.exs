# What `Describe.request/1` does with bytes a VM can send. Run with:
#
#     MIX_ENV=test mix run --no-start test/review/hostile_text/describe_probe.exs
alias MDTClient.Sandbox.Describe

rlo = <<0x202E::utf8>>
hidden = ~r/[\x{202A}-\x{202E}\x{2066}-\x{2069}\x{200B}-\x{200F}\x00-\x08\x0b-\x1f]/u

probe = fn label, request ->
  result =
    try do
      d = Describe.request(request)
      texts = [d.title, d.pattern] ++ Enum.flat_map(d.facts ++ d.claims, fn {a, b} -> [a, b] end)

      cond do
        not Enum.all?(texts, &String.valid?/1) -> "INVALID UTF-8 in the description"
        Enum.any?(texts, &(&1 =~ hidden)) -> "HIDDEN characters in the description"
        true -> "ok"
      end
    rescue
      e -> "RAISES " <> String.slice(Exception.message(e), 0, 80)
    end

  IO.puts(String.pad_trailing(label, 40) <> result)
end

base = %{host: "github.com", method: "GET", path: "/", headers: [], body: ""}
zeros = String.duplicate("0", 40)
ones = String.duplicate("1", 40)
line = "#{zeros} #{ones} refs/heads/\xff\xfe\0 report-status"
pkt = String.pad_leading(Integer.to_string(byte_size(line) + 4, 16), 4, "0") <> line <> "0000"

probe.("refs with a bad percent escape", %{base | path: "/a/b/info/refs?service=%zz"})
probe.("path with a raw 0xff byte", %{base | path: "/repos/\xff"})
probe.("user-agent of raw bytes", %{base | headers: [{"user-agent", "curl\xff\xfe"}]})

probe.("user-agent with a bidi override", %{
  base
  | headers: [{"user-agent", "curl " <> rlo <> "gnp.exe"}]
})

probe.("JSON title with a bidi override", %{
  base
  | method: "POST",
    path: "/repos/a/b/issues",
    body: Jason.encode!(%{title: "safe " <> rlo <> " txet"})
})

probe.("push of a ref of raw bytes", %{
  base
  | method: "POST",
    path: "/a/b.git/git-receive-pack",
    body: pkt
})

probe.("graphql nested 5000 deep", %{
  base
  | method: "POST",
    path: "/graphql",
    body: Jason.encode!(%{query: String.duplicate("{a", 5000)})
})

probe.("graphql body of raw bytes", %{
  base
  | method: "POST",
    path: "/graphql",
    body: <<255, 254, 0, 1>>
})

probe.("host of raw bytes", %{base | host: "\xff.github.com"})
