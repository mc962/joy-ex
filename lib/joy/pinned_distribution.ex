defmodule Joy.PinnedDistribution do
  @moduledoc """
  Horde distribution strategy that pins a channel's OTP tree to a specific node.

  When the child spec contains a non-nil `pinned_node` string, this strategy finds
  the matching alive cluster member and returns it. Falls back to
  `Horde.UniformDistribution` if the named node is not currently in the cluster.

  The `pinned_node` field is set in `Joy.Channel.Supervisor.child_spec/1` from
  `channel.pinned_node`. A nil value (the default) uses uniform distribution.

  # GO-TRANSLATION:
  # No direct equivalent — Go has no concept of distributed OTP supervisors.
  # Closest analogy: a Kubernetes pod affinity rule that schedules a deployment
  # to a specific node via nodeSelector.
  """

  @behaviour Horde.DistributionStrategy

  @impl true
  def choose_node(%{pinned_node: node_str} = child_spec, members) when is_binary(node_str) do
    target_node = String.to_existing_atom(node_str)
    alive = Enum.filter(members, fn m -> m.status == :alive end)

    case Enum.find(alive, fn %{name: {_, node}} -> node == target_node end) do
      nil    -> Horde.UniformDistribution.choose_node(child_spec, members)
      member -> {:ok, member}
    end
  rescue
    # String.to_existing_atom raises ArgumentError if the atom has never been created,
    # which means the node is not connected to this cluster — fall back to uniform.
    ArgumentError -> Horde.UniformDistribution.choose_node(child_spec, members)
  end

  @impl true
  def choose_node(child_spec, members),
    do: Horde.UniformDistribution.choose_node(child_spec, members)

  @impl true
  def has_quorum?(members),
    do: Horde.UniformDistribution.has_quorum?(members)
end
