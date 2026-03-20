defmodule Joy.HL7.Message do
  @moduledoc """
  Struct representing a parsed HL7 v2.x message.

  Segments are stored as `%{name: "PID", fields: ["PID", "1", "12345", ...]}` where
  `fields[0]` is the segment name and `fields[n]` is field n (HL7 is 1-based, list is 0-indexed).

  `routes` is set by the `route/2` DSL function. Empty = deliver to all enabled destinations.

  # GO-TRANSLATION:
  # type Message struct { Raw string; Segments []Segment; ... }
  # Accessor.set/3 returns a new Message (immutable). Go would copy the struct and mutate.
  """

  @type segment :: %{name: String.t(), fields: [String.t()]}

  @type t :: %__MODULE__{
          raw: String.t() | nil,
          segments: [segment()],
          field_sep: String.t(),
          comp_sep: String.t(),
          rep_sep: String.t(),
          esc_char: String.t(),
          sub_sep: String.t(),
          routes: [atom() | String.t()]
        }

  defstruct raw: nil,
            segments: [],
            field_sep: "|",
            comp_sep: "^",
            rep_sep: "~",
            esc_char: "\\",
            sub_sep: "&",
            routes: []
end
