defmodule Membrane.Element.Base.Sink do
  @moduledoc """
  This module should be used by all elements that are sinks.
  """


  defmacro __using__(_) do
    quote location: :keep do
      use Membrane.Element.Base.Mixin.Process
      use Membrane.Element.Base.Mixin.Sink
    end
  end
end
