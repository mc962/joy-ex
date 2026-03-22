defmodule Joy.Repo.Migrations.AddPauseAndAlertToChannels do
  use Ecto.Migration

  def change do
    alter table(:channels) do
      # Channel Pause/Resume
      add :paused, :boolean, null: false, default: false

      # Alerting on Sustained Failures
      add :alert_enabled, :boolean, null: false, default: false
      add :alert_threshold, :integer, null: false, default: 5
      add :alert_email, :string
      add :alert_webhook_url, :string
      add :alert_cooldown_minutes, :integer, null: false, default: 60
    end
  end
end
