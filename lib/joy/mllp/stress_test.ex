defmodule Joy.MLLP.StressTest do
  @moduledoc """
  Concurrent MLLP load runner for the test client UI.

  `run/7` streams N messages to an endpoint with a configurable concurrency
  level. Each message is freshly generated with randomized patient data so
  that deduplication (keyed on MSH.10 message control ID) does not filter
  them out and the full pipeline is exercised on every message.

  Each result is sent back to the caller LiveView process as it completes,
  enabling live progress updates.

  # GO-TRANSLATION: errgroup.WithContext + semaphore pattern for concurrency,
  # channel for streaming results back to the caller goroutine.
  """

  @first_names ~w(Alice Bob Carol David Emma Frank Grace Henry Iris James
                  Karen Leo Mia Nathan Olivia Paul Quinn Rose Sam Tara)
  @last_names  ~w(Smith Jones Brown Taylor Wilson Davis Miller Moore Anderson
                  Thomas Jackson White Harris Martin Thompson Garcia Martinez)

  @doc """
  Send `count` generated messages of `message_type` to `host:port`, up to
  `concurrency` at a time. Sends `{:stress_result, {:ok, latency_ms} | {:error, reason}}`
  to `caller_pid` for each message, then `{:stress_complete, aggregate}` when done.

  `message_type` is one of: `:adt_a01`, `:oru_r01`, `:orm_o01`

  Options: `:timeout_ms`, `:delay_ms` (inter-message delay within each task).
  """
  @spec run(pid(), String.t(), pos_integer(), atom(), pos_integer(), pos_integer(), keyword()) ::
          :ok
  def run(caller_pid, host, port, message_type, count, concurrency, opts \\ []) do
    delay_ms = Keyword.get(opts, :delay_ms, 0)
    client_opts = Keyword.take(opts, [:timeout_ms])

    results =
      1..count
      |> Task.async_stream(
        fn _i ->
          if delay_ms > 0, do: Process.sleep(delay_ms)
          hl7 = generate_hl7(message_type)

          case Joy.MLLP.Client.send_message(host, port, hl7, client_opts) do
            {:ok, %{latency_ms: ms}} -> {:ok, ms}
            {:error, reason} -> {:error, reason}
          end
        end,
        max_concurrency: concurrency,
        timeout: :infinity,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} ->
          send(caller_pid, {:stress_result, result})
          result

        {:exit, reason} ->
          r = {:error, reason}
          send(caller_pid, {:stress_result, r})
          r
      end)

    send(caller_pid, {:stress_complete, aggregate(results)})
    :ok
  end

  @doc "Generate a single randomized HL7 message of the given type."
  @spec generate_hl7(atom()) :: String.t()
  def generate_hl7(message_type) do
    patient = random_patient()
    now = DateTime.utc_now() |> Calendar.strftime("%Y%m%d%H%M%S")
    control_id = :crypto.strong_rand_bytes(6) |> Base.encode16()

    case message_type do
      :adt_a01 -> adt_a01(patient, now, control_id)
      :oru_r01 -> oru_r01(patient, now, control_id)
      :orm_o01 -> orm_o01(patient, now, control_id)
    end
  end

  @doc "Compute aggregate stats from a list of per-message results."
  @spec aggregate([{:ok, non_neg_integer()} | {:error, term()}]) :: map()
  def aggregate(results) do
    latencies = for {:ok, ms} <- results, do: ms
    errors = for {:error, _} <- results, do: 1

    %{
      total: length(results),
      ok: length(latencies),
      failed: length(errors),
      min_ms: if(latencies == [], do: nil, else: Enum.min(latencies)),
      max_ms: if(latencies == [], do: nil, else: Enum.max(latencies)),
      avg_ms:
        if(latencies == [],
          do: nil,
          else: round(Enum.sum(latencies) / length(latencies))
        )
    }
  end

  # --- Private generators ---

  defp adt_a01(%{mrn: mrn, last: last, first: first, dob: dob, sex: sex}, now, ctrl) do
    "MSH|^~\\&|JoyStress|StressFac|RecvApp|RecvFac|#{now}||ADT^A01|#{ctrl}|P|2.5\r" <>
    "EVN|A01|#{now}\r" <>
    "PID|1||#{mrn}^^^MRN^MR||#{last}^#{first}||#{dob}|#{sex}|||#{random_address()}\r" <>
    "PV1|1|I|#{random_bed()}||||#{random_provider()}|||SUR||||1|||#{random_provider()}|IP\r"
  end

  defp oru_r01(%{mrn: mrn, last: last, first: first, dob: dob, sex: sex}, now, ctrl) do
    order_id = :crypto.strong_rand_bytes(4) |> Base.encode16()
    {sodium, potassium, glucose, creatinine} = random_bmp_values()

    "MSH|^~\\&|JoyStress|LAB_FAC|RCV|RCV_FAC|#{now}||ORU^R01|#{ctrl}|P|2.5\r" <>
    "PID|1||#{mrn}^^^MRN^MR||#{last}^#{first}||#{dob}|#{sex}\r" <>
    "OBR|1|#{order_id}|RES#{order_id}|80048^BASIC METABOLIC PANEL^CPT|||#{now}\r" <>
    "OBX|1|NM|2951-2^SODIUM^LN||#{sodium}|mmol/L|136-145|#{abnormal_flag(sodium, 136, 145)}|||F\r" <>
    "OBX|2|NM|2823-3^POTASSIUM^LN||#{potassium}|mmol/L|3.5-5.0|#{abnormal_flag_f(potassium, 3.5, 5.0)}|||F\r" <>
    "OBX|3|NM|2345-7^GLUCOSE^LN||#{glucose}|mg/dL|70-100|#{abnormal_flag(glucose, 70, 100)}|||F\r" <>
    "OBX|4|NM|2160-0^CREATININE^LN||#{creatinine}|mg/dL|0.6-1.2|#{abnormal_flag_f(creatinine, 0.6, 1.2)}|||F\r"
  end

  defp orm_o01(%{mrn: mrn, last: last, first: first, dob: dob, sex: sex}, now, ctrl) do
    order_id = :crypto.strong_rand_bytes(4) |> Base.encode16()
    test = Enum.random([
      "85025^CBC WITH DIFFERENTIAL^CPT",
      "80053^COMPREHENSIVE METABOLIC PANEL^CPT",
      "84443^TSH^CPT",
      "86900^ABO GROUP^CPT",
      "83036^HEMOGLOBIN A1C^CPT"
    ])

    "MSH|^~\\&|JoyStress|OE_FAC|LAB|LAB_FAC|#{now}||ORM^O01|#{ctrl}|P|2.5\r" <>
    "PID|1||#{mrn}^^^MRN^MR||#{last}^#{first}||#{dob}|#{sex}\r" <>
    "ORC|NW|#{order_id}||||||#{now}|||#{random_provider()}\r" <>
    "OBR|1|#{order_id}||#{test}|||#{now}\r"
  end

  defp random_patient do
    year  = 1940 + :rand.uniform(65)
    month = :rand.uniform(12)
    day   = :rand.uniform(28)
    dob   = :io_lib.format("~4..0B~2..0B~2..0B", [year, month, day]) |> to_string()

    %{
      mrn:   "STRESS-" <> (:rand.uniform(999_999) |> Integer.to_string() |> String.pad_leading(6, "0")),
      last:  Enum.random(@last_names),
      first: Enum.random(@first_names),
      dob:   dob,
      sex:   Enum.random(["M", "F"])
    }
  end

  defp random_address do
    num    = :rand.uniform(9999)
    street = Enum.random(["Main St", "Oak Ave", "Maple Dr", "Cedar Ln", "Elm St"])
    city   = Enum.random(["Springfield", "Shelbyville", "Ogdenville", "Brockway"])
    state  = Enum.random(["IL", "OH", "IN", "MI", "WI"])
    zip    = :rand.uniform(89999) + 10000
    "#{num} #{street}^^#{city}^#{state}^#{zip}"
  end

  defp random_bed do
    floor = :rand.uniform(5)
    room  = :rand.uniform(20)
    bed   = Enum.random(["A", "B"])
    "#{floor}-#{room}-#{bed}^#{room * 10 + floor}^01"
  end

  defp random_provider do
    last  = Enum.random(@last_names)
    first = Enum.random(@first_names)
    npi   = :rand.uniform(9_999_999) + 1_000_000
    "#{npi}^#{last}^#{first}"
  end

  defp random_bmp_values do
    sodium     = 128 + :rand.uniform(24)        # 129–152 (straddles 136–145)
    potassium  = (30 + :rand.uniform(30)) / 10  # 3.1–6.0
    glucose    = 60 + :rand.uniform(80)         # 61–140 (straddles 70–100)
    creatinine = (5 + :rand.uniform(20)) / 10   # 0.6–2.5
    {sodium, potassium, glucose, creatinine}
  end

  defp abnormal_flag(val, low, _high) when val < low, do: "L"
  defp abnormal_flag(val, _low, high) when val > high, do: "H"
  defp abnormal_flag(_, _, _), do: ""

  defp abnormal_flag_f(val, low, _high) when val < low, do: "L"
  defp abnormal_flag_f(val, _low, high) when val > high, do: "H"
  defp abnormal_flag_f(_, _, _), do: ""
end
