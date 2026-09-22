defmodule MDTClient.Git.Error do
  @moduledoc "An error returned by the Git backend."

  alias MDTClient.Git.Operation

  @type kind ::
          :command_failed
          | :conflict
          | :git_not_found
          | :invalid_argument
          | :invalid_output
          | :invalid_repository
          | :unsupported

  @type t :: %__MODULE__{
          kind: kind(),
          message: String.t(),
          args: [String.t()],
          exit_status: non_neg_integer() | nil,
          output: String.t(),
          operation: Operation.t() | nil
        }

  defexception kind: :command_failed,
               message: "Git command failed",
               args: [],
               exit_status: nil,
               output: "",
               operation: nil

  @doc false
  def command(args, exit_status, output) do
    message =
      case String.trim(output) do
        "" -> "Git exited with status #{exit_status}"
        output -> output
      end

    %__MODULE__{
      kind: :command_failed,
      message: message,
      args: args,
      exit_status: exit_status,
      output: output
    }
  end

  @doc false
  def new(kind, message), do: %__MODULE__{kind: kind, message: message}
end
