defmodule Membrane.Core.Element.PadController do
  @moduledoc false

  # Module handling linking and unlinking pads.

  use Bunch
  alias Membrane.Core.{CallbackHandler, Child, Events}

  alias Membrane.Core.Element.{
    ActionHandler,
    AtomicDemand,
    AutoFlowController,
    CallbackContext,
    EffectiveFlowController,
    EventController,
    State,
    StreamFormatController
  }

  alias Membrane.Core.Element.ManualFlowController.InputQueue

  alias Membrane.Core.Parent.Link.Endpoint
  alias Membrane.LinkError

  require Membrane.Core.Child.PadModel, as: PadModel
  require Membrane.Core.Message, as: Message
  require Membrane.Core.Stalker, as: Stalker
  require Membrane.Logger
  require Membrane.Pad, as: Pad

  @type link_call_props :: %{
          optional(:output_pad_info) => PadModel.pad_info() | nil,
          optional(:link_metadata) => map(),
          optional(:output_effective_flow_control) =>
            EffectiveFlowController.effective_flow_control(),
          :stream_format_validation_params =>
            StreamFormatController.stream_format_validation_params()
        }

  @type link_call_reply_props ::
          {Endpoint.t(), PadModel.pad_info(), %{atomic_demand: AtomicDemand.t()}}

  @type link_call_reply ::
          :ok
          | {:ok, link_call_reply_props}
          | {:error, {:neighbor_dead, reason :: any()}}
          | {:error, {:neighbor_child_dead, reason :: any()}}
          | {:error, {:unknown_pad, name :: Membrane.Child.name(), pad_ref :: Pad.ref()}}

  @default_auto_demand_size_factor 400

  @doc """
  Verifies linked pad, initializes it's data.
  """
  @spec handle_link(Pad.direction(), Endpoint.t(), Endpoint.t(), link_call_props, State.t()) ::
          {link_call_reply, State.t()}
  def handle_link(direction, endpoint, other_endpoint, link_props, state) do
    Membrane.Logger.debug(
      "Element handle link on pad #{inspect(endpoint.pad_ref)} with pad #{inspect(other_endpoint.pad_ref)} of child #{inspect(other_endpoint.child)}"
    )

    pad_name = Pad.name_by_ref(endpoint.pad_ref)

    pad_info =
      case Map.fetch(state.pads_info, pad_name) do
        {:ok, pad_info} ->
          pad_info

        :error ->
          raise LinkError,
                "Tried to link via unknown pad #{inspect(pad_name)} of #{inspect(state.name)}"
      end

    :ok = Child.PadController.validate_pad_direction!(direction, pad_info)
    do_handle_link(direction, endpoint, other_endpoint, pad_info, link_props, state)
  end

  defp do_handle_link(:output, endpoint, input_endpoint, pad_info, link_props, state) do
    pad_effective_flow_control =
      EffectiveFlowController.get_pad_effective_flow_control(endpoint.pad_ref, state)

    handle_link_response =
      Message.call(input_endpoint.pid, :handle_link, [
        :input,
        input_endpoint,
        endpoint,
        %{
          output_pad_info: pad_info,
          link_metadata: %{
            observability_data: Stalker.generate_observability_data_for_link(endpoint.pad_ref)
          },
          stream_format_validation_params: [],
          output_effective_flow_control: pad_effective_flow_control
        }
      ])

    case handle_link_response do
      {:ok, {input_endpoint, input_pad_info, link_metadata}} ->
        state =
          init_pad_data(
            endpoint,
            input_endpoint,
            pad_info,
            link_props.stream_format_validation_params,
            :push,
            input_pad_info,
            link_metadata,
            state
          )

        state = maybe_handle_pad_added(endpoint.pad_ref, state)
        {:ok, state}

      {:error, {:call_failure, reason}} ->
        Membrane.Logger.debug("""
        Tried to link pad #{inspect(endpoint.pad_ref)}, but neighbour #{inspect(input_endpoint.child)}
        is not alive.
        """)

        {{:error, {:neighbor_dead, reason}}, state}

      {:error, {:unknown_pad, _name, _pad_ref}} = error ->
        {error, state}

      {:error, {:child_dead, reason}} ->
        {{:error, {:neighbor_child_dead, reason}}, state}
    end
  end

  defp do_handle_link(:input, input_endpoint, output_endpoint, pad_info, link_props, state) do
    %{
      output_pad_info: output_pad_info,
      link_metadata: link_metadata,
      stream_format_validation_params: stream_format_validation_params,
      output_effective_flow_control: output_effective_flow_control
    } = link_props

    {output_demand_unit, input_demand_unit} = resolve_demand_units(output_pad_info, pad_info)

    link_metadata =
      Map.merge(link_metadata, %{
        input_demand_unit: input_demand_unit,
        output_demand_unit: output_demand_unit
      })

    pad_effective_flow_control =
      EffectiveFlowController.get_pad_effective_flow_control(input_endpoint.pad_ref, state)

    atomic_demand =
      AtomicDemand.new(%{
        receiver_effective_flow_control: pad_effective_flow_control,
        receiver_process: self(),
        receiver_demand_unit: input_demand_unit || :buffers,
        sender_process: output_endpoint.pid,
        sender_pad_ref: output_endpoint.pad_ref,
        supervisor: state.subprocess_supervisor,
        toilet_capacity: input_endpoint.pad_props[:toilet_capacity],
        throttling_factor: input_endpoint.pad_props[:throttling_factor]
      })

    Stalker.register_link(
      state.stalker,
      input_endpoint.pad_ref,
      output_endpoint.pad_ref,
      link_metadata.observability_data
    )

    link_metadata =
      link_metadata
      |> Map.merge(%{
        atomic_demand: atomic_demand,
        observability_data:
          Stalker.generate_observability_data_for_link(
            input_endpoint.pad_ref,
            link_metadata.observability_data
          )
      })

    :ok =
      Child.PadController.validate_pads_flow_control_compability!(
        output_endpoint.pad_ref,
        output_pad_info.flow_control,
        input_endpoint.pad_ref,
        pad_info.flow_control
      )

    state =
      init_pad_data(
        input_endpoint,
        output_endpoint,
        pad_info,
        stream_format_validation_params,
        output_effective_flow_control,
        output_pad_info,
        link_metadata,
        state
      )

    state =
      case PadModel.get_data!(state, input_endpoint.pad_ref) do
        %{flow_control: :auto, direction: :input} = pad_data ->
          EffectiveFlowController.handle_sender_effective_flow_control(
            pad_data.ref,
            pad_data.other_effective_flow_control,
            state
          )

        _pad_data ->
          state
      end

    state = maybe_handle_pad_added(input_endpoint.pad_ref, state)

    {{:ok, {input_endpoint, pad_info, link_metadata}}, state}
  end

  @doc """
  Handles situation where pad has been unlinked (e.g. when connected element has been removed from pipeline)

  Removes pad data.
  Signals an EoS (via handle_event) to the element if unlinked pad was an input.
  Executes `handle_pad_removed` callback if the pad was dynamic.
  Note: it also flushes all buffers from PlaybackBuffer.
  """
  @spec handle_unlink(Pad.ref(), State.t()) :: State.t()
  def handle_unlink(pad_ref, state) do
    with {:ok, %{availability: :on_request}} <- PadModel.get_data(state, pad_ref) do
      Stalker.unregister_link(state.stalker, pad_ref)
      state = generate_eos_if_needed(pad_ref, state)
      state = maybe_handle_pad_removed(pad_ref, state)

      {pad_data, state} =
        Map.update!(state, :pad_refs, &List.delete(&1, pad_ref))
        |> PadModel.pop_data!(pad_ref)

      with %{direction: :input, flow_control: :auto, other_effective_flow_control: :pull} <-
             pad_data do
        EffectiveFlowController.resolve_effective_flow_control(state)
      else
        _pad_data -> state
      end
      |> Map.update!(:satisfied_auto_output_pads, &MapSet.delete(&1, pad_ref))
      |> Map.update!(:awaiting_auto_input_pads, &MapSet.delete(&1, pad_ref))
      |> Map.update!(:auto_input_pads, &List.delete(&1, pad_ref))
      |> AutoFlowController.pop_queues_and_bump_demand()
    else
      {:ok, %{availability: :always}} when state.terminating? ->
        state

      {:ok, %{availability: :always}} ->
        raise Membrane.PadError,
              "Tried to unlink a static pad #{inspect(pad_ref)}. Static pads cannot be unlinked unless element is terminating"

      {:error, :unknown_pad} ->
        with false <- state.terminating?,
             %{availability: :always} <- state.pads_info[Pad.name_by_ref(pad_ref)] do
          raise Membrane.PadError,
                "Tried to unlink a static pad #{inspect(pad_ref)}, before it was linked. Static pads cannot be unlinked unless element is terminating"
        end

        Membrane.Logger.debug(
          "Ignoring unlinking pad #{inspect(pad_ref)} that hasn't been successfully linked"
        )

        state
    end
  end

  defp resolve_demand_units(output_info, input_info) do
    output_demand_unit = output_info[:demand_unit] || input_info[:demand_unit] || :buffers
    input_demand_unit = input_info[:demand_unit] || output_info[:demand_unit] || :buffers

    {output_demand_unit, input_demand_unit}
  end

  defp init_pad_data(
         endpoint,
         other_endpoint,
         pad_info,
         stream_format_validation_params,
         other_effective_flow_control,
         other_pad_info,
         metadata,
         state
       ) do
    total_buffers_metric = :atomics.new(1, [])

    Membrane.Core.Stalker.register_metric_function(
      :total_buffers,
      fn -> :atomics.get(total_buffers_metric, 1) end,
      pad: endpoint.pad_ref
    )

    Membrane.Core.Stalker.register_metric_function(
      :atomic_demand,
      fn -> AtomicDemand.get(metadata.atomic_demand) end,
      pad: endpoint.pad_ref
    )

    pad_data =
      pad_info
      |> Map.delete(:accepted_formats_str)
      |> Map.merge(%{
        pid: other_endpoint.pid,
        other_ref: other_endpoint.pad_ref,
        options:
          Child.PadController.parse_pad_options!(pad_info.name, endpoint.pad_props.options, state),
        ref: endpoint.pad_ref,
        stream_format_validation_params: stream_format_validation_params,
        other_effective_flow_control: other_effective_flow_control,
        stream_format: nil,
        start_of_stream?: false,
        end_of_stream?: false,
        atomic_demand: metadata.atomic_demand,
        stalker_metrics: %{
          total_buffers: total_buffers_metric
        }
      })
      |> merge_pad_direction_data(metadata, state)
      |> merge_pad_mode_data(endpoint.pad_props, other_pad_info, state)
      |> then(&struct!(Membrane.Element.PadData, &1))

    state =
      state
      |> put_in([:pads_data, endpoint.pad_ref], pad_data)
      |> Map.update!(:pad_refs, &[endpoint.pad_ref | &1])

    :ok =
      AtomicDemand.set_sender_status(
        pad_data.atomic_demand,
        {:resolved, EffectiveFlowController.get_pad_effective_flow_control(pad_data.ref, state)}
      )

    case pad_data do
      %{direction: :output, flow_control: :auto} ->
        Map.update!(state, :satisfied_auto_output_pads, &MapSet.put(&1, pad_data.ref))

      %{direction: :input, flow_control: :auto} ->
        AutoFlowController.auto_adjust_atomic_demand(endpoint.pad_ref, state)
        |> Map.update!(:auto_input_pads, &[endpoint.pad_ref | &1])

      _pad_data ->
        state
    end
  end

  defp merge_pad_direction_data(%{direction: :input} = pad_data, metadata, _state) do
    pad_data
    |> Map.merge(%{
      sticky_messages: [],
      demand_unit: metadata.input_demand_unit,
      other_demand_unit: metadata.output_demand_unit
    })
  end

  defp merge_pad_direction_data(%{direction: :output} = pad_data, metadata, _state) do
    pad_data
    |> Map.merge(%{
      demand_unit: metadata.output_demand_unit,
      other_demand_unit: metadata.input_demand_unit
    })
  end

  defp merge_pad_mode_data(
         %{direction: :input, flow_control: :manual} = pad_data,
         pad_props,
         other_pad_info,
         %State{}
       ) do
    %{
      ref: ref,
      demand_unit: this_demand_unit,
      atomic_demand: atomic_demand
    } = pad_data

    input_queue =
      InputQueue.new(%{
        inbound_demand_unit: other_pad_info[:demand_unit] || this_demand_unit,
        outbound_demand_unit: this_demand_unit,
        atomic_demand: atomic_demand,
        pad_ref: ref,
        log_tag: inspect(ref),
        target_size: pad_props.target_queue_size
      })

    pad_data
    |> Map.merge(%{
      input_queue: input_queue,
      demand: 0
    })
  end

  defp merge_pad_mode_data(
         %{direction: :output, flow_control: :manual} = pad_data,
         _pad_props,
         _other_pad_info,
         _state
       ) do
    Map.put(pad_data, :demand, 0)
  end

  defp merge_pad_mode_data(
         %{flow_control: :auto, direction: direction} = pad_data,
         pad_props,
         _other_info,
         _state
       ) do
    auto_demand_size =
      cond do
        direction == :output ->
          nil

        pad_props.auto_demand_size != nil ->
          pad_props.auto_demand_size

        true ->
          demand_unit = pad_data.other_demand_unit || pad_data.demand_unit || :buffers
          metric = Membrane.Buffer.Metric.from_unit(demand_unit)
          metric.buffer_size_approximation() * @default_auto_demand_size_factor
      end

    demand_metric =
      if direction == :input do
        :atomics.new(1, [])
        |> tap(
          &Stalker.register_metric_function(
            :auto_demand_size,
            fn -> :atomics.get(&1, 1) end,
            pad: pad_data.ref
          )
        )
      end

    pad_data
    |> Map.merge(%{
      demand: 0,
      auto_demand_size: auto_demand_size
    })
    |> put_in([:stalker_metrics, :demand], demand_metric)
  end

  defp merge_pad_mode_data(pad_data, _props, _other_info, _state), do: pad_data

  @doc """
  Generates end of stream on the given input pad if it hasn't been generated yet
  and playback is `playing`.
  """
  @spec generate_eos_if_needed(Pad.ref(), State.t()) :: State.t()
  def generate_eos_if_needed(pad_ref, state) do
    %{direction: direction, end_of_stream?: eos?} = PadModel.get_data!(state, pad_ref)

    if direction == :input and not eos? and state.playback == :playing do
      EventController.exec_handle_event(pad_ref, %Events.EndOfStream{}, state)
    else
      state
    end
  end

  @spec maybe_handle_pad_added(Pad.ref(), State.t()) :: State.t()
  defp maybe_handle_pad_added(ref, state) do
    %{options: pad_opts, availability: availability} = PadModel.get_data!(state, ref)

    if Pad.availability_mode(availability) == :dynamic do
      context = &CallbackContext.from_state(&1, pad_options: pad_opts)

      CallbackHandler.exec_and_handle_callback(
        :handle_pad_added,
        ActionHandler,
        %{context: context},
        [ref],
        state
      )
    else
      state
    end
  end

  @spec maybe_handle_pad_removed(Pad.ref(), State.t()) :: State.t()
  defp maybe_handle_pad_removed(ref, state) do
    %{availability: availability} = PadModel.get_data!(state, ref)

    if Pad.availability_mode(availability) == :dynamic do
      CallbackHandler.exec_and_handle_callback(
        :handle_pad_removed,
        ActionHandler,
        %{context: &CallbackContext.from_state/1},
        [ref],
        state
      )
    else
      state
    end
  end
end
