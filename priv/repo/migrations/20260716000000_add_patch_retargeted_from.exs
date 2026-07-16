defmodule BorsNG.Database.Repo.Migrations.AddPatchRetargetedFrom do
  use Ecto.Migration

  def change do
    alter table(:patches) do
      add(:retargeted_from, :string)
    end
  end
end
