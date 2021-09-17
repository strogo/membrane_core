defmodule Membrane.Bin.CallbackContext.CrashGroupDown do
  @moduledoc """
  Structure representing a context that is passed to the pipeline
  when a crash group is down.
  """
  use Membrane.Core.Bin.CallbackContext,
    members: [Membrane.Child.name_t()],
    first_crashed_child: Membrane.Child.name_t()
end
