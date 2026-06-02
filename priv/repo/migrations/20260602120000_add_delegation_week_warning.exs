defmodule BorsNG.Database.Repo.Migrations.AddDelegationWeekWarning do
  use Ecto.Migration

  def change do
    alter table(:user_patch_delegations) do
      add(:week_warning_sent_at, :naive_datetime)
    end
  end
end
