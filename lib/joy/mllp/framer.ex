defmodule Joy.MLLP.Framer do
  @moduledoc """
  MLLP (Minimum Lower Layer Protocol) framing for HL7 over TCP.

  Frame format: <<0x0B>> <HL7 message bytes> <<0x1C, 0x0D>>
  - 0x0B = VT (Vertical Tab) = start-of-block
  - 0x1C = FS (File Separator) = end-of-block
  - 0x0D = CR = end marker

  This module is stateless — all framing state lives in the connection's
  receive buffer. The framer simply produces and parses frame boundaries.

  # GO-TRANSLATION:
  # Go: bytes.Index(data, []byte{0x1C, 0x0D}) to find frame end.
  # Elixir binary pattern matching is more expressive:
  #   <<0x0B, rest::binary>> — match and consume start byte.
  # :binary.match/2 finds the end marker in the remaining bytes.
  """

  @sb 0x0B
  @eb 0x1C
  @cr 0x0D

  @doc "Wrap an HL7 string in MLLP framing bytes."
  @spec wrap(String.t()) :: binary()
  def wrap(hl7_string), do: <<@sb>> <> hl7_string <> <<@eb, @cr>>

  @doc """
  Attempt to extract a complete MLLP frame from a binary buffer.

  Returns:
    - `{:ok, message_string, rest}` — complete frame found
    - `:incomplete` — frame start found but end not yet received
    - `{:error, :invalid_frame}` — unrecognizable data
  """
  @spec unwrap(binary()) :: {:ok, String.t(), binary()} | :incomplete | {:error, :invalid_frame}
  def unwrap(<<@sb, rest::binary>>) do
    case :binary.match(rest, <<@eb, @cr>>) do
      {pos, _len} ->
        message = binary_part(rest, 0, pos)
        remainder = binary_part(rest, pos + 2, byte_size(rest) - pos - 2)
        {:ok, message, remainder}
      :nomatch ->
        :incomplete
    end
  end
  # Lenient: if no 0x0B but looks like HL7 (starts with MSH), still parse it
  def unwrap(<<"MSH", _::binary>> = data) do
    case :binary.match(data, <<@eb, @cr>>) do
      {pos, _} ->
        message = binary_part(data, 0, pos)
        remainder = binary_part(data, pos + 2, byte_size(data) - pos - 2)
        {:ok, message, remainder}
      :nomatch ->
        :incomplete
    end
  end
  def unwrap(<<>>), do: :incomplete
  def unwrap(_), do: {:error, :invalid_frame}

  @doc "Build a complete MLLP-framed ACK response for an incoming HL7 message."
  @spec build_ack(Joy.HL7.Message.t(), :aa | :ae | :ar) :: binary()
  def build_ack(original_msg, code) do
    original_msh = Joy.HL7.find_segment(original_msg, "MSH") || %{fields: []}
    fs = original_msg.field_sep
    cs = original_msg.comp_sep
    rs = original_msg.rep_sep
    ec = original_msg.esc_char
    ss = original_msg.sub_sep

    # Swap sender/receiver: MSH.3/4 ↔ MSH.5/6
    sending_app  = field(original_msh, 5)
    sending_fac  = field(original_msh, 6)
    receiving_app = field(original_msh, 3)
    receiving_fac = field(original_msh, 4)
    orig_control_id = field(original_msh, 10)
    new_control_id = :crypto.strong_rand_bytes(4) |> Base.encode16()
    now = DateTime.utc_now() |> Calendar.strftime("%Y%m%d%H%M%S")
    version = field(original_msh, 12) || "2.5"

    msh = Enum.join([
      "MSH",
      cs <> rs <> ec <> ss,
      sending_app,
      sending_fac,
      receiving_app,
      receiving_fac,
      now,
      "",
      "ACK",
      new_control_id,
      "P",
      version
    ], fs)

    msa = Enum.join(["MSA", code_string(code), orig_control_id || ""], fs)

    wrap(msh <> "\r" <> msa)
  end

  defp field(%{fields: fields}, idx), do: Enum.at(fields, idx, "")
  defp field(_, _), do: ""

  defp code_string(:aa), do: "AA"
  defp code_string(:ae), do: "AE"
  defp code_string(:ar), do: "AR"
end
