defmodule Joy.HL7.SegmentOrder do
  @moduledoc """
  Canonical HL7 v2 segment ordering.

  After a transform script runs, the segment list is sorted against this map so
  that new segments created by set/3 appear in their correct position rather than
  appended to the end.

  Priority tiers:
    0–999   — known standard segments, sorted by their position in this map
    10_000  — unknown segments (not in map, not Z-prefix); stable relative order preserved
    20_000  — Z-segments (custom); always last, stable relative order preserved
  """

  alias Joy.HL7.Message

  @order %{
    # Header / acknowledgment
    "MSH" => 0,   "SFT" => 1,   "UAC" => 2,
    "MSA" => 10,  "ERR" => 11,  "QAK" => 12,  "QRD" => 13,
    # Event / patient
    "EVN" => 20,
    "PID" => 30,  "PD1" => 31,  "ARV" => 32,  "ROL" => 33,  "NK1" => 34,
    # Visit
    "PV1" => 40,  "PV2" => 41,
    # Clinical
    "DB1" => 50,  "OBX" => 51,  "AL1" => 52,  "DG1" => 53,  "DRG" => 54,
    "PR1" => 55,  "GT1" => 56,
    # Insurance
    "IN1" => 60,  "IN2" => 61,  "IN3" => 62,
    # Financial / accident
    "ACC" => 70,  "UB1" => 71,  "UB2" => 72,
    # Orders / results
    "ORC" => 80,  "OBR" => 81,  "TQ1" => 82,  "TQ2" => 83,
    "NTE" => 84,  "CTD" => 85,  "CTI" => 86,  "BLG" => 87,  "TXA" => 88,
    # Scheduling
    "SCH" => 90,  "RGS" => 91,  "AIS" => 92,  "AIG" => 93,  "AIL" => 94,  "AIP" => 95,
    # Referral
    "RF1" => 100, "AUT" => 101,
    # Master files
    "MFI" => 110, "MFE" => 111, "STF" => 112, "PRA" => 113,
    "ORG" => 114, "AFF" => 115, "LAN" => 116, "EDU" => 117, "CER" => 118,
  }

  @doc """
  Sort a message's segment list into canonical HL7 v2 order.
  MSH is always first. Z-segments always last. Unknown segments between.
  Stable: relative order is preserved within each priority tier.
  """
  @spec sort(Message.t()) :: Message.t()
  def sort(%Message{segments: segments} = msg) do
    sorted =
      segments
      |> Enum.with_index()
      |> Enum.sort_by(fn {%{name: name}, idx} -> {priority(name), idx} end)
      |> Enum.map(&elem(&1, 0))
    %{msg | segments: sorted}
  end

  defp priority("Z" <> _), do: {20_000, 0}
  defp priority(name) do
    case Map.get(@order, name) do
      nil -> {10_000, 0}
      n   -> {0, n}
    end
  end
end
