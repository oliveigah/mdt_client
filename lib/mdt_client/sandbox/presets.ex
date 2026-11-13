defmodule MDTClient.Sandbox.Presets do
  @moduledoc """
  What the add dialog offers: the four grant types, and presets that fill a
  type's form for tools whose details are known.

  A preset only fills fields. The grant it makes is a plain `:token`,
  `:network`, `:file` or `:command` grant that you can edit like any other, and nothing
  else in MDT looks at which preset made it, apart from its icon.

  The VM-side details come from the checks of 2026-11-11: `gh` sends
  `Authorization: token`, git sends the token as the Basic password after a
  401, Hex sends the whole header value, gcloud reads a bearer token from the
  file `CLOUDSDK_AUTH_ACCESS_TOKEN_FILE` names. See `docs/agent_sandbox.md`.
  """

  @typedoc """
  A type or a preset. `fields` are the add form's params it starts from:
  `"purpose"`, `"env"`, `"file_env"`, `"hosts"`, `"git"`, `"prefix"`,
  `"source"`, `"mint"`, `"destinations"`, `"path"`.
  """
  @type t :: %{
          id: atom(),
          kind: MDTClient.Sandbox.Grant.kind(),
          name: String.t(),
          icon: String.t(),
          blurb: String.t(),
          guide: [String.t()],
          fields: %{String.t() => String.t()}
        }

  @types [
    %{
      id: :token,
      kind: :token,
      name: "Token or API key",
      icon: "hero-key",
      blurb: "A secret sent in HTTP requests: API keys, bearer tokens, git over HTTPS.",
      guide: [
        "Create the token as restricted and short-lived as the service allows.",
        "List the hosts it is sent to. The VM gets a placeholder; MDT swaps in the real value only on requests to these hosts.",
        "Name the variables the tool reads (STRIPE_API_KEY, say). Any header carrying the placeholder is swapped, Basic credentials included."
      ],
      fields: %{"source" => "stored", "prefix" => "mdt_"}
    },
    %{
      id: :network,
      kind: :network,
      name: "Network access",
      icon: "hero-signal",
      blurb: "Hosts and address ranges behind your VPN or on your network.",
      guide: [
        "Connect your VPN on this machine as usual.",
        "List what the VM may reach, one per line: 10.20.0.0/16:443,5432 or git.corp.internal:443.",
        "Each connection waits for your approval unless you allow them for a while."
      ],
      fields: %{}
    },
    %{
      id: :file,
      kind: :file,
      name: "File",
      icon: "hero-document-text",
      blurb: "A value a tool must read itself: kubeconfig, signing keys, .env values.",
      guide: [
        "Use this only when a tool must read the value itself: a key that signs, a kubeconfig with client certificates.",
        "The content is written to /mnt/mdt/files/NAME while the grant is on. Anything that reads it can keep a copy.",
        "Prefer a value that expires, and revoke it at its provider when done."
      ],
      fields: %{}
    },
    %{
      id: :command,
      kind: :command,
      name: "Command on this machine",
      icon: "hero-command-line",
      blurb: "Lets agents ask to run a command here, as you. Each run waits for your approval.",
      guide: [
        "Use it for a job that needs something only this machine has: your SSH keys, a kubeconfig, your VPN. The work goes to the value, and only its output goes back.",
        "With a script of yours, agents can run only that text, in the folder you name. Leave the script empty and they write the text themselves: the widest grant there is.",
        "Either way, every run shows on a card and waits for you. Nothing lets one through unasked."
      ],
      fields: %{}
    }
  ]

  @presets [
    %{
      id: :github,
      kind: :token,
      name: "GitHub",
      icon: "git-branch",
      blurb: "gh, git over HTTPS and the REST and GraphQL APIs.",
      guide: [
        "Create a fine-grained token at github.com/settings/personal-access-tokens with an expiry.",
        "Give it only the repositories the agent works on, and only what it needs: Contents read and write to push, Pull requests to open them.",
        "Paste it below. In the VM, gh and git get a placeholder; git asks MDT's credential helper for it."
      ],
      fields: %{
        "purpose" => "GitHub: gh, git over HTTPS and the GitHub API.",
        "env" => "GITHUB_TOKEN, GH_TOKEN",
        "hosts" => "api.github.com, github.com, uploads.github.com",
        "git" => "true",
        "prefix" => "ghp_",
        "source" => "stored"
      }
    },
    %{
      id: :hex,
      kind: :token,
      name: "Hex",
      icon: "hero-cube",
      blurb: "mix hex.publish, owners and private packages.",
      guide: [
        "On this machine, run mix hex.user key generate --key-name agent-sandbox --permission api:write, or create a key at hex.pm/dashboard/keys.",
        "Prefer a key limited to the packages the agent publishes.",
        "Paste it below. In the VM, mix reads the placeholder from HEX_API_KEY."
      ],
      fields: %{
        "purpose" => "Hex: publishing packages and reading private ones.",
        "env" => "HEX_API_KEY",
        "hosts" => "hex.pm, repo.hex.pm",
        "prefix" => "mdt_",
        "source" => "stored"
      }
    },
    %{
      id: :google,
      kind: :token,
      name: "Google Cloud",
      icon: "hero-cloud",
      blurb: "Short-lived tokens minted on this machine for gcloud and Google APIs.",
      guide: [
        "Log in on this machine as you normally do: gcloud auth login.",
        "MDT runs the command below whenever the VM needs a token and keeps the result for 10 minutes. Your login stays here; the VM only sees a placeholder.",
        "gcloud auth print-access-token acts as you. Add --impersonate-service-account=NAME@PROJECT.iam.gserviceaccount.com to act as a narrower service account instead."
      ],
      fields: %{
        "purpose" => "Google Cloud: gcloud and Google APIs.",
        "file_env" => "CLOUDSDK_AUTH_ACCESS_TOKEN_FILE",
        "hosts" => "*.googleapis.com",
        "prefix" => "ya29.mdt",
        "source" => "minted",
        "mint" => "gcloud auth print-access-token"
      }
    },
    %{
      id: :database,
      kind: :network,
      name: "Database tunnel",
      icon: "hero-circle-stack",
      blurb: "A tunnel on this machine holds the login; the VM only reaches the tunnel.",
      guide: [
        "Run a tunnel on this machine that holds the login, such as cloud-sql-proxy --auto-iam-authn --port 5433 PROJECT:REGION:INSTANCE.",
        "List exactly the tunnel's address and port here. This is the only way the VM reaches this machine.",
        "In the VM, connect to that address with no password."
      ],
      fields: %{
        "purpose" => "A database, through a tunnel on the user's machine.",
        "destinations" => "127.0.0.1:5433"
      }
    }
  ]

  @doc "The three grant types, in the order the add dialog shows them."
  @spec types() :: [t()]
  def types, do: @types

  @doc "The presets, in the order the add dialog shows them."
  @spec presets() :: [t()]
  def presets, do: @presets

  @doc "Looks a type or preset up by the string a form sends."
  @spec find(String.t()) :: {:ok, t()} | :error
  def find(id) when is_binary(id) do
    case Enum.find(@types ++ @presets, &(Atom.to_string(&1.id) == id)) do
      nil -> :error
      found -> {:ok, found}
    end
  end

  @doc "The type itself, for a grant's kind."
  @spec type(MDTClient.Sandbox.Grant.kind()) :: t()
  def type(kind), do: Enum.find(@types, &(&1.kind == kind))

  @doc "The icon of a grant: its preset's, or its type's."
  @spec icon(MDTClient.Sandbox.Grant.t() | nil) :: String.t()
  def icon(nil), do: "hero-key"

  def icon(%{preset: preset, kind: kind}) do
    case Enum.find(@presets, &(&1.id == preset)) do
      nil -> type(kind).icon
      found -> found.icon
    end
  end

  @doc "What a grant's type is called."
  @spec kind_name(MDTClient.Sandbox.Grant.kind()) :: String.t()
  def kind_name(kind), do: type(kind).name
end
