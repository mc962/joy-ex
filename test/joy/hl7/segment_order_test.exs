defmodule Joy.HL7.SegmentOrderTest do
  use ExUnit.Case, async: true

  alias Joy.HL7.{Message, SegmentOrder}

  defp msg(names) do
    segments = Enum.map(names, &%{name: &1, fields: [&1]})
    %Message{segments: segments}
  end

  defp names(%Message{segments: segments}), do: Enum.map(segments, & &1.name)

  describe "sort/1" do
    test "MSH always first" do
      assert names(SegmentOrder.sort(msg(["PID", "MSH", "EVN"]))) == ["MSH", "EVN", "PID"]
    end

    test "Z-segments always last" do
      result = names(SegmentOrder.sort(msg(["ZPD", "PID", "MSH", "ZAB"])))
      assert List.first(result) == "MSH"
      assert Enum.take(result, -2) == ["ZPD", "ZAB"]
    end

    test "new Z-segment added before known segment sorts correctly" do
      # Simulates: transform writes ZPD.1 then PID.5 — ZPD was appended first
      result = names(SegmentOrder.sort(msg(["MSH", "ZPD", "PID"])))
      assert result == ["MSH", "PID", "ZPD"]
    end

    test "unknown segments sort between known and Z-segments" do
      result = names(SegmentOrder.sort(msg(["MSH", "ZZZ", "PID", "XYZ"])))
      assert result == ["MSH", "PID", "XYZ", "ZZZ"]
    end

    test "stable: relative order preserved within each tier" do
      # Two OBX segments should stay in original relative order
      segs = [
        %{name: "MSH", fields: ["MSH"]},
        %{name: "OBX", fields: ["OBX", "1"]},
        %{name: "PID", fields: ["PID"]},
        %{name: "OBX", fields: ["OBX", "2"]}
      ]
      result = SegmentOrder.sort(%Message{segments: segs})
      obx_fields = result.segments |> Enum.filter(&(&1.name == "OBX")) |> Enum.map(&Enum.at(&1.fields, 1))
      assert obx_fields == ["1", "2"]
    end

    test "already-ordered message is unchanged" do
      ordered = ["MSH", "PID", "PV1", "OBX"]
      assert names(SegmentOrder.sort(msg(ordered))) == ordered
    end

    test "empty segment list" do
      assert SegmentOrder.sort(%Message{segments: []}).segments == []
    end
  end
end
