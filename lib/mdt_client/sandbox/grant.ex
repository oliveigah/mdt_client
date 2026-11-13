defmodule MDTClient.Sandbox.Grant do
  @moduledoc """
  One piece of access the VM can be given, and taken back from, on the spot.

  Four types, none tied to a provider:

    * `:token` - a secret that travels in HTTP requests: an API key, a bearer
      token, git's password. The VM holds a placeholder, in the `env`
      variables, in the token file (`token_file/1`, which `file_env`
      variables point at) and, when `git` is set, as git's password for
      `hosts`. MDT swaps the real value in on requests to `hosts`.
    * `:network` - reachability to `destinations`; nothing to hold.
    * `:file` - the real value, as a file at `path`; copies outlive turning
      it off.
    * `:command` - nothing to hold: while it is on, agents may ask MDT to
      run a command on your machine. With a `script`, only that text, in
      `dir`; with none, any text they send. Every run waits for you; no
      allowance covers one. No such grant exists until you add it, so a new
      identity runs nothing on your machine for the VM.

  `purpose` is the user's own words for what the grant is for. Agents read it
  to find the grant they need, so every grant has one. `preset` remembers
  which preset filled the form, for its icon; nothing else depends on it.

  Every use of an `on` grant waits for the user unless one of its
  `allowances` covers it. See `MDTClient.Sandbox.Allowance`.

  See `docs/agent_sandbox.md` for the whole model.
  """

  alias MDTClient.Sandbox.Allowance

  @enforce_keys [:id, :name, :kind]
  defstruct [
    :id,
    :name,
    :kind,
    :preset,
    :expires_at,
    :placeholder,
    :path,
    :script,
    :dir,
    :last_used_at,
    purpose: "",
    state: :off,
    source: :stored,
    env: [],
    file_env: [],
    git: false,
    hosts: [],
    destinations: [],
    allowances: [],
    uses: 0
  ]

  @type kind :: :token | :network | :file | :command
  @type source :: :stored | {:minted, String.t()}

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          kind: kind(),
          preset: atom() | nil,
          purpose: String.t(),
          state: :on | :off,
          expires_at: DateTime.t() | nil,
          placeholder: String.t() | nil,
          path: String.t() | nil,
          script: String.t() | nil,
          dir: String.t() | nil,
          last_used_at: DateTime.t() | nil,
          source: source(),
          env: [String.t()],
          file_env: [String.t()],
          git: boolean(),
          hosts: [String.t()],
          destinations: [String.t()],
          allowances: [Allowance.t()],
          uses: non_neg_integer()
        }

  @kinds [:token, :network, :file, :command]

  @doc "Every type a grant can have."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "Whether the VM ends up holding the real value, which no switch can take back."
  @spec exposes_value?(t()) :: boolean()
  def exposes_value?(%__MODULE__{kind: kind}), do: kind == :file

  @doc """
  Whether the grant is on at `now`. One past its `expires_at` is not, even
  while its `state` still says `:on`: the clock decides, not a timer.
  """
  @spec on?(t(), DateTime.t()) :: boolean()
  def on?(grant, now \\ DateTime.utc_now())
  def on?(%__MODULE__{state: :on, expires_at: nil}, _now), do: true
  def on?(%__MODULE__{state: :on, expires_at: at}, now), do: DateTime.compare(now, at) == :lt
  def on?(%__MODULE__{}, _now), do: false

  @doc "Where the VM finds a token grant's placeholder as a file."
  @spec token_file(t()) :: String.t()
  def token_file(%__MODULE__{id: id}), do: "/mnt/mdt/tokens/" <> id

  @doc "The hosts git's credential helper answers for: the exact ones, when `git` is set."
  @spec git_hosts(t()) :: [String.t()]
  def git_hosts(%__MODULE__{kind: :token, git: true, hosts: hosts}),
    do: Enum.reject(hosts, &String.starts_with?(&1, "*."))

  def git_hosts(%__MODULE__{}), do: []

  @doc """
  Brings a grant saved by an older MDT up to date. Before 2026-11-12 a grant
  had a `recipe` (`:github`, `:hex`, `:google`, `:token`, `:network`,
  `:database`, `:file`) and the type `:http`, and its rules decided which
  requests went through. Rules are gone: every use asks.
  """
  @spec upgrade(map()) :: t()
  def upgrade(%{} = saved) do
    fields = Map.delete(saved, :__struct__)
    recipe = fields[:recipe]

    {env, file_env} =
      if recipe == :google,
        do: {[], fields[:env] || []},
        else: {fields[:env] || [], fields[:file_env] || []}

    upgraded = %{
      kind: if(fields[:kind] == :http, do: :token, else: fields[:kind]),
      preset: fields[:preset] || if(recipe in [:github, :hex, :google, :database], do: recipe),
      purpose: fields[:purpose] || old_purpose(recipe),
      env: env,
      file_env: file_env,
      git: Map.get(fields, :git, recipe == :github),
      allowances:
        for(%{} = allowance <- fields[:allowances] || [], do: Allowance.upgrade(allowance))
    }

    struct(__MODULE__, Map.merge(fields, upgraded))
  end

  defp old_purpose(:github), do: "GitHub: gh, git over HTTPS and the GitHub API."
  defp old_purpose(:hex), do: "Hex: publishing and private packages."
  defp old_purpose(:google), do: "Google Cloud: gcloud and Google APIs."
  defp old_purpose(:database), do: "A database, through a tunnel on the user's machine."
  defp old_purpose(_recipe), do: ""
end
