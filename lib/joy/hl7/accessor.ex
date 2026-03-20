defmodule Joy.HL7.Accessor do
  @moduledoc """
  Path-based read/write access for HL7 v2.x messages.

  Path notation (1-based, per HL7 convention):
    "MSH.9"       — segment MSH, field 9
    "PID.5.1"     — segment PID, field 5, component 1
    "OBX[2].5"    — second OBX segment (1-based), field 5

  Returns nil for missing paths rather than errors — real HL7 is often sparse.

  # GO-TRANSLATION:
  # func Get(msg Message, path string) (string, bool) — explicit "found" bool.
  # Elixir nil return + pattern matching makes sparse access natural.
  # Set returns a new Message (immutable); Go would mutate a copy.
  """

  alias Joy.HL7.Message

  @doc "Get a field value by path. Returns nil if not found."
  @spec get(Message.t(), String.t()) :: String.t() | nil
  def get(%Message{} = msg, path) when is_binary(path) do
    with {seg_name, seg_idx, field_idx, comp_idx} <- parse_path(path),
         %{fields: fields} <- find_segment(msg, seg_name, seg_idx),
         field when not is_nil(field) <- Enum.at(fields, field_idx) do
      if comp_idx do
        field
        |> String.split(msg.comp_sep)
        |> Enum.at(comp_idx - 1)
      else
        field
      end
    else
      _ -> nil
    end
  end
  def get(_, _), do: nil

  @doc "Set a field value by path. Creates missing segments/fields as needed."
  @spec set(Message.t(), String.t(), String.t()) :: Message.t()
  def set(%Message{} = msg, path, value) when is_binary(path) and is_binary(value) do
    case parse_path(path) do
      {seg_name, seg_idx, field_idx, comp_idx} ->
        # Find or create segment
        {seg_list_idx, segment} = find_or_create_segment(msg, seg_name, seg_idx)

        new_segment = update_field(segment, field_idx, comp_idx, value, msg.comp_sep)

        new_segments =
          if seg_list_idx == :new do
            msg.segments ++ [new_segment]
          else
            List.replace_at(msg.segments, seg_list_idx, new_segment)
          end

        %{msg | segments: new_segments}

      _ ->
        msg
    end
  end
  def set(msg, _, _), do: msg

  @doc "Remove all segments with the given name."
  @spec delete_segment(Message.t(), String.t()) :: Message.t()
  def delete_segment(%Message{} = msg, seg_name) do
    %{msg | segments: Enum.reject(msg.segments, &(&1.name == seg_name))}
  end

  @doc "Find the nth occurrence (0-based) of a segment by name."
  @spec find_segment(Message.t(), String.t(), non_neg_integer()) :: map() | nil
  def find_segment(%Message{segments: segs}, name, occurrence \\ 0) do
    segs
    |> Enum.filter(&(&1.name == name))
    |> Enum.at(occurrence)
  end

  # Returns {seg_name, seg_occurrence_0based, field_idx_0based, comp_idx_1based_or_nil}
  defp parse_path(path) do
    parts = String.split(path, ".")

    case parts do
      [seg_part | rest] ->
        {seg_name, seg_idx} = parse_seg_part(seg_part)
        [field_str | comp_rest] = rest ++ [nil]

        with field_idx when not is_nil(field_idx) <- parse_int(field_str) do
          comp_idx = parse_int(List.first(comp_rest))
          {seg_name, seg_idx, field_idx, comp_idx}
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_seg_part(part) do
    case Regex.run(~r/^([A-Z0-9]{2,3})(?:\[(\d+)\])?$/, part) do
      [_, name] -> {name, 0}
      [_, name, idx_str] -> {name, String.to_integer(idx_str) - 1}
      _ -> {part, 0}
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp find_or_create_segment(%Message{segments: segs}, name, occurrence) do
    matching_indices =
      segs
      |> Enum.with_index()
      |> Enum.filter(fn {seg, _i} -> seg.name == name end)
      |> Enum.map(fn {seg, i} -> {i, seg} end)

    case Enum.at(matching_indices, occurrence) do
      nil -> {:new, %{name: name, fields: [name]}}
      {i, seg} -> {i, seg}
    end
  end

  defp update_field(segment, field_idx, comp_idx, value, comp_sep) do
    fields = segment.fields
    # Pad fields list to at least field_idx + 1 elements
    padded = pad_list(fields, field_idx + 1, "")

    new_fields =
      if comp_idx do
        raw_field = Enum.at(padded, field_idx) || ""
        components = String.split(raw_field, comp_sep)
        new_components = pad_list(components, comp_idx, "") |> List.replace_at(comp_idx - 1, value)
        List.replace_at(padded, field_idx, Enum.join(new_components, comp_sep))
      else
        List.replace_at(padded, field_idx, value)
      end

    %{segment | fields: new_fields}
  end

  defp pad_list(list, min_length, fill) do
    current = length(list)
    if current >= min_length do
      list
    else
      list ++ List.duplicate(fill, min_length - current)
    end
  end
end
