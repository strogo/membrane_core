defmodule Membrane.Mixins.CallbackHandler do
  @moduledoc """
  Behaviour for module that delegates its job to the other module via callbacks.
  It also delivers the default implementation of logic that handles the results
  of callbacks.
  """

  use Membrane.Helper
  use Membrane.Mixins.Log, tags: :core

  @type callback_return_t(action_t, internal_state_t) ::
          {:ok, internal_state_t}
          | {{:ok, [action_t]}, internal_state_t}
          | {{:error, any}, internal_state_t}

  @callback handle_action(action :: any, callback :: atom, handler_params :: map, state) ::
              {:ok, state} | {{:error, reason :: any}, state}
            when state: any
  @callback handle_actions(actions :: list, callback :: atom, handler_params :: map, state) ::
              {:ok, state} | {{:error, reason :: any}, state}
            when state: any

  defmacro __using__(_args) do
    quote location: :keep do
      alias unquote(__MODULE__)
      @behaviour unquote(__MODULE__)

      @impl unquote(__MODULE__)
      def handle_actions(actions, callback, handler_params, state) do
        actions
        |> Membrane.Helper.Enum.reduce_with(state, fn action, state ->
          handle_action(action, callback, handler_params, state)
        end)
      end

      defoverridable unquote(__MODULE__)
    end
  end

  def exec_and_handle_callback(callback, handler_module, handler_params \\ %{}, args, state)
      when is_map(handler_params) do
    result = callback |> exec_callback(args, state)
    result |> handle_callback_result(callback, handler_module, handler_params, state)
  end

  def exec_and_handle_splitted_callback(
        callback,
        original_callback,
        handler_module,
        handler_params \\ %{},
        args_list,
        state
      )
      when is_map(handler_params) do
    split_cont_f = handler_params[:split_cont_f] || fn _ -> true end

    args_list
    |> Helper.Enum.reduce_while_with(state, fn args, state ->
      if split_cont_f.(state) do
        result = callback |> exec_callback(args |> Helper.listify(), state)

        result
        |> handle_callback_result(original_callback, handler_module, handler_params, state)
        ~>> ({:ok, state} -> {:ok, {:cont, state}})
      else
        {:ok, {:halt, state}}
      end
    end)
  end

  defp exec_callback(callback, args, state) do
    internal_state = state |> Map.get(:internal_state)
    module = state |> Map.get(:module)
    module |> apply(callback, args ++ [internal_state])
  end

  defp handle_callback_result(result, callback, handler_module, handler_params, state) do
    module = state |> Map.get(:module)

    with {:ok, {result, new_internal_state}} <-
           result
           |> parse_callback_result(module, callback),
         state = state |> Map.put(:internal_state, new_internal_state),
         {:ok, actions} <- result,
         {:ok, state} <-
           actions
           |> exec_handle_actions(callback, handler_module, handler_params, state) do
      {:ok, state}
    end
  end

  defp exec_handle_actions(actions, callback, handler_module, handler_params, state) do
    with {:ok, state} <- actions |> handler_module.handle_actions(callback, handler_params, state) do
      {:ok, state}
    else
      {{:error, reason}, state} ->
        warn("""
        Error while handling actions returned by callback #{inspect(callback)}
        """)

        {{:error, {:error_handling_actions, reason}}, state}
    end
  end

  defp parse_callback_result({:ok, new_internal_state}, module, cb),
    do: parse_callback_result({{:ok, []}, new_internal_state}, module, cb)

  defp parse_callback_result({{:ok, actions}, new_internal_state}, _module, _cb)
       when is_list(actions) do
    {:ok, {{:ok, actions}, new_internal_state}}
  end

  defp parse_callback_result({{:error, reason}, new_internal_state}, module, cb) do
    warn_error(
      """
      Callback #{inspect(cb)} from module #{inspect(module)} returned an error
      Internal state: #{inspect(new_internal_state)}
      """,
      reason
    )

    {:ok, {{:error, reason}, new_internal_state}}
  end

  defp parse_callback_result(result, module, cb) do
    warn_error(
      """
      Callback replies are expected to be one of:

          {:ok, state}
          {{:ok, actions}, state}
          {{:error, reason}, state}

      where actions is a list that is specific to #{inspect(module)}

      Instead, callback #{inspect(cb)} from module #{inspect(module)} returned
      value of #{inspect(result)} which does not match any of the valid return
      values.

      Check if all callbacks return values are in the right format.
      """,
      {:invalid_callback_result, result: result, module: module, callback: cb}
    )
  end
end
