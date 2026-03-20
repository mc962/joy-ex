defmodule Joy.HL7.Parser do
  @moduledoc """
  Lenient HL7 v2.x parser. Handles real-world messiness: missing MLLP framing,
  mixed line endings, malformed MSH, trailing garbage.

  Why lenient: healthcare integrations live and die by interoperability with legacy
  systems. A strict parser that crashes on minor deviations is a patient safety risk.
  We parse what we can and return the best-effort result.

  # GO-TRANSLATION:
  # Go: bytes.Split(data, []byte{0x0D}), then string processing.
  # Elixir binary pattern matching strips MLLP bytes more expressively.
  # {:ok, value} | {:error, reason} maps to (value, error) in Go.
  """

  alias Joy.HL7.Message

  @mllp_sb 0x0B
  @mllp_eb 0x1C

  @doc "Parse raw HL7 string (with or without MLLP framing) into a Message struct."
  @spec parse(String.t()) :: {:ok, Message.t()} | {:error, String.t()}
  def parse(raw) when is_binary(raw) do
    stripped = strip_mllp(raw) |> String.trim()

    if stripped == "" do
      {:error, "Empty message"}
    else
      {field_sep, comp_sep, rep_sep, esc_char, sub_sep} = parse_delimiters(stripped)

      segments =
        stripped
        |> String.split(~r/\r\n|\r|\n/)
        |> Enum.reject(&(String.trim(&1) == ""))
        |> Enum.map(&parse_segment(&1, field_sep))

      {:ok,
       %Message{
         raw: raw,
         segments: segments,
         field_sep: field_sep,
         comp_sep: comp_sep,
         rep_sep: rep_sep,
         esc_char: esc_char,
         sub_sep: sub_sep
       }}
    end
  end

  def parse(_), do: {:error, "Input must be a binary string"}

  # Strip MLLP start-of-block (0x0B) and end-of-block (0x1C + optional 0x0D)
  defp strip_mllp(<<@mllp_sb, rest::binary>>) do
    rest
    |> String.trim_trailing(<<@mllp_eb, 0x0D>>)
    |> String.trim_trailing(<<@mllp_eb>>)
  end
  defp strip_mllp(data), do: data

  # Extract delimiters from MSH segment. Falls back to defaults for malformed MSH.
  defp parse_delimiters(data) do
    case data do
      <<"MSH", fs::binary-1, enc::binary-4, _::binary>> ->
        comp = String.at(enc, 0) || "^"
        rep  = String.at(enc, 1) || "~"
        esc  = String.at(enc, 2) || "\\"
        sub  = String.at(enc, 3) || "&"
        {fs, comp, rep, esc, sub}
      _ ->
        {"|", "^", "~", "\\", "&"}
    end
  end

  defp parse_segment(line, field_sep) do
    fields = String.split(line, field_sep)
    name = fields |> List.first("") |> String.slice(0, 3) |> String.trim()
    %{name: name, fields: fields}
  end
end
