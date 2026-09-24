defmodule MDTClient.Git.Commit do
  @moduledoc """
  Commit metadata used by the graph and commit inspector.

  `labels` holds every reference pointing at this commit: local and remote
  branches, and the tags that resolve to it. `signature_status` is `nil` when
  the signature was not checked, which is how the graph loads commits; see
  `MDTClient.Git.Core.signature/2`.
  """

  alias MDTClient.Git.Branch
  alias MDTClient.Git.Tag

  @enforce_keys [
    :id,
    :parents,
    :author_name,
    :author_email,
    :authored_at,
    :committer_name,
    :committer_email,
    :committed_at,
    :summary,
    :body,
    :signature_status,
    :labels
  ]
  defstruct [
    :id,
    :parents,
    :author_name,
    :author_email,
    :authored_at,
    :committer_name,
    :committer_email,
    :committed_at,
    :summary,
    :body,
    :signature_status,
    :signature_signer,
    :labels
  ]

  @type signature_status ::
          :good
          | :bad
          | :good_unknown_validity
          | :good_expired
          | :good_expired_key
          | :good_revoked_key
          | :cannot_check
          | :no_signature
          | :unknown

  @type t :: %__MODULE__{
          id: String.t(),
          parents: [String.t()],
          author_name: String.t(),
          author_email: String.t(),
          authored_at: DateTime.t(),
          committer_name: String.t(),
          committer_email: String.t(),
          committed_at: DateTime.t(),
          summary: String.t(),
          body: String.t(),
          signature_status: signature_status() | nil,
          signature_signer: String.t() | nil,
          labels: [Branch.t() | Tag.t()]
        }
end
