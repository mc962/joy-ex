defmodule Joy.HL7 do
  @moduledoc """
  Public API for HL7 v2 parsing and field manipulation.

  Delegates to Joy.HL7.Parser (parsing) and Joy.HL7.Accessor (field access).
  This module is the stable external interface — callers should import only this,
  not the internal parser/accessor modules directly.

  # GO-TRANSLATION:
  # Package-level functions forwarding to internal packages. Identical pattern.
  """

  alias Joy.HL7.{Parser, Accessor, Message}

  defdelegate parse(raw), to: Parser
  defdelegate get(msg, path), to: Accessor
  defdelegate set(msg, path, value), to: Accessor
  defdelegate delete_segment(msg, seg_name), to: Accessor
  defdelegate find_segment(msg, seg_name, occurrence \\ 0), to: Accessor

  @doc "Reassemble a parsed Message struct back into a raw HL7 string."
  @spec to_string(Message.t()) :: String.t()
  def to_string(%Message{segments: segments, field_sep: fs, comp_sep: cs,
                          rep_sep: rs, esc_char: ec, sub_sep: ss}) do
    segments
    |> Enum.map(fn %{name: name, fields: fields} ->
      if name == "MSH" do
        # fields layout: [0]="MSH", [1]=field_sep (MSH.1), [2]=enc_chars (MSH.2), [3..n]=MSH.3+
        # Reconstruct from the struct's delimiter fields so any edits to them are preserved.
        enc_chars = cs <> rs <> ec <> ss
        Enum.join(["MSH", enc_chars | Enum.drop(fields, 3)], fs)
      else
        Enum.join(fields, fs)
      end
    end)
    |> Enum.join("\r")
  end
end
