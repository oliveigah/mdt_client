defmodule MDTClient.Sandbox.Recipes do
  @moduledoc """
  What each kind of credential needs, so adding a grant starts from the
  safest delivery available and sensible rules.

  The VM-side details (env vars, carriers, CA variables) come from the checks
  of 2026-11-11: `gh` sends `Authorization: token`, git sends the token as the
  Basic password after a 401, Hex sends the whole header value, gcloud sends a
  bearer token. See `docs/agent_sandbox.md`.
  """

  alias MDTClient.Sandbox.Rule

  @type recipe :: %{
          id: atom(),
          name: String.t(),
          icon: String.t(),
          kind: MDTClient.Sandbox.Grant.kind(),
          blurb: String.t(),
          guide: [String.t()],
          env: [String.t()],
          hosts: [String.t()],
          carriers: [String.t()],
          destinations: [String.t()],
          path: String.t() | nil,
          source: :stored | :minted,
          rules: [Rule.t()]
        }

  @doc "Every recipe, in the order the add dialog offers them."
  @spec all() :: [recipe()]
  def all do
    [
      %{
        id: :github,
        name: "GitHub token",
        icon: "git-branch",
        kind: :http,
        blurb: "gh, git over HTTPS and the REST and GraphQL APIs.",
        guide: [
          "Create a fine-grained token at github.com/settings/personal-access-tokens with an expiry.",
          "Give it only the repositories the agent works on, and only what it needs: Contents read and write to push, Pull requests to open them.",
          "Paste it below. In the VM, gh and git get a placeholder; git asks MDT's credential helper for it."
        ],
        env: ["GITHUB_TOKEN", "GH_TOKEN"],
        hosts: ["api.github.com", "github.com", "uploads.github.com"],
        carriers: ["Authorization: token / Bearer", "Basic password (git)"],
        destinations: [],
        path: nil,
        source: :stored,
        rules: github_rules()
      },
      %{
        id: :hex,
        name: "Hex API key",
        icon: "hero-cube",
        kind: :http,
        blurb: "mix hex.publish, owners and private packages.",
        guide: [
          "On this machine, run mix hex.user key generate --key-name agent-sandbox --permission api:write, or create a key at hex.pm/dashboard/keys.",
          "Prefer a key limited to the packages the agent publishes.",
          "Paste it below. In the VM, mix reads the placeholder from HEX_API_KEY."
        ],
        env: ["HEX_API_KEY"],
        hosts: ["hex.pm", "repo.hex.pm"],
        carriers: ["Authorization (whole value)"],
        destinations: [],
        path: nil,
        source: :stored,
        rules: [
          rule("reads", "Reads", "GET, HEAD and OPTIONS on any path", :allow, "read"),
          rule("writes", "Publish, retire, owners", "Every other method", :ask, "write")
        ]
      },
      %{
        id: :google,
        name: "Google Cloud",
        icon: "hero-cloud",
        kind: :http,
        blurb: "Short-lived tokens minted on this machine for gcloud and Google APIs.",
        guide: [
          "Log in on this machine as you normally do: gcloud auth login.",
          "MDT runs the command below whenever the VM needs a token and keeps the result for 10 minutes. Your login stays here; the VM only sees a placeholder, swapped for a token on its way out.",
          "gcloud auth print-access-token acts as you. Add --impersonate-service-account=NAME@PROJECT.iam.gserviceaccount.com to act as a narrower service account instead."
        ],
        env: ["CLOUDSDK_AUTH_ACCESS_TOKEN_FILE"],
        hosts: ["*.googleapis.com"],
        carriers: ["Authorization: Bearer"],
        destinations: [],
        path: nil,
        source: :minted,
        rules: [
          rule("reads", "Reads", "GET, HEAD and OPTIONS on any path", :allow, "read"),
          rule("writes", "Changes", "Every other method", :ask, "write")
        ]
      },
      %{
        id: :token,
        name: "API token",
        icon: "hero-key",
        kind: :http,
        blurb: "Any service that takes a token in a header.",
        guide: [
          "Create a token in the service's dashboard, as restricted and short-lived as it allows.",
          "Name the variable the client reads (STRIPE_API_KEY, say) and the hosts the token is sent to.",
          "Any header carrying the placeholder is swapped, including Basic credentials."
        ],
        env: [],
        hosts: [],
        carriers: ["Authorization: Bearer"],
        destinations: [],
        path: nil,
        source: :stored,
        rules: [rule("all", "Every request", "Any method, any path", :ask, "any")]
      },
      %{
        id: :network,
        name: "Network access",
        icon: "hero-signal",
        kind: :network,
        blurb: "Hosts and address ranges behind your VPN or on your network.",
        guide: [
          "Connect your VPN on this machine as usual.",
          "List what the VM may reach, one per line: 10.20.0.0/16:443,5432 or git.corp.internal:443.",
          "Connections ask for approval by default; you can let them through on the grant's page."
        ],
        env: [],
        hosts: [],
        carriers: [],
        destinations: [],
        path: nil,
        source: :stored,
        rules: []
      },
      %{
        id: :database,
        name: "Database tunnel",
        icon: "hero-circle-stack",
        kind: :network,
        blurb: "A tunnel on this machine holds the login; the VM only reaches the tunnel.",
        guide: [
          "Run a tunnel on this machine that holds the login, such as cloud-sql-proxy --auto-iam-authn --port 5433 PROJECT:REGION:INSTANCE.",
          "List exactly the tunnel's address and port here. This is the only way the VM reaches this machine.",
          "In the VM, connect to that address with no password."
        ],
        env: [],
        hosts: [],
        carriers: [],
        destinations: ["127.0.0.1:5433"],
        path: nil,
        source: :stored,
        rules: []
      },
      %{
        id: :file,
        name: "File",
        icon: "hero-document-text",
        kind: :file,
        blurb: "Anything a tool must read itself: kubeconfig, signing keys, .env values.",
        guide: [
          "Use this only when a tool must read the value itself: a key that signs, a kubeconfig with client certificates.",
          "The content is written to /mnt/mdt/files/NAME while the grant is on. Anything that reads it can keep a copy.",
          "Prefer a value that expires, and revoke it at its provider when done."
        ],
        env: [],
        hosts: [],
        carriers: [],
        destinations: [],
        path: "/mnt/mdt/files/",
        source: :stored,
        rules: []
      }
    ]
  end

  @doc "Fetches a recipe by id, raising when it is unknown."
  @spec fetch!(atom()) :: recipe()
  def fetch!(id),
    do: Enum.find(all(), &(&1.id == id)) || raise(ArgumentError, "unknown recipe #{inspect(id)}")

  @doc "Looks a recipe up by the string a form sends."
  @spec find(String.t()) :: {:ok, recipe()} | :error
  def find(id) when is_binary(id) do
    case Enum.find(all(), &(Atom.to_string(&1.id) == id)) do
      nil -> :error
      recipe -> {:ok, recipe}
    end
  end

  @doc "The default GitHub rules: reads go through, anything that writes asks."
  @spec github_rules() :: [Rule.t()]
  def github_rules do
    [
      rule("reads", "Reads", "GET, HEAD and OPTIONS on any path", :allow, "read"),
      rule("fetch", "git fetch and clone", "POST …/git-upload-pack", :allow, "git_fetch"),
      rule("queries", "GraphQL queries", "POST /graphql with a query", :allow, "graphql_query"),
      rule("push", "git push", "POST …/git-receive-pack", :ask, "git_push"),
      rule(
        "mutations",
        "GraphQL mutations",
        "POST /graphql with a mutation",
        :ask,
        "graphql_mutation"
      ),
      rule("writes", "Other writes", "POST, PUT, PATCH, DELETE elsewhere", :ask, "write")
    ]
  end

  defp rule(id, label, match, action, tag) do
    %Rule{id: id, label: label, match: match, action: action, tag: tag}
  end
end
