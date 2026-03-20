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
        # MSH is special: MSH.1 = field_sep, MSH.2 = encoding chars
        # fields[0]="MSH", fields[1]=field_sep, fields[2]=enc_chars, fields[3..n]=normal
        enc_chars = cs <> rs <> ec <> ss
        msh_fields = [
          "MSH",
          # field 2 onwards separated by field_sep — but MSH.1 is the sep itself
          enc_chars | Enum.drop(fields, 2)
        ]
        "MSH" <> fs <> Enum.join(Enum.drop(msh_fields, 1), fs)
      else
        Enum.join(fields, fs)
      end
    end)
    |> Enum.join("\r")
  end
end
