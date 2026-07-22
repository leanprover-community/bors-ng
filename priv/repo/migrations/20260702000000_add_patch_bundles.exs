defmodule BorsNG.Database.Repo.Migrations.AddPatchBundles do
  use Ecto.Migration

  def change do
    create table(:patch_bundles) do
      add(:project_id, references(:projects, on_delete: :delete_all), null: false)
      timestamps()
    end

    create(index(:patch_bundles, [:project_id]))

    alter table(:patches) do
      add(:bundle_id, references(:patch_bundles, on_delete: :nilify_all))
      add(:bundle_reviewer, :string)
      add(:stacked_on_id, references(:patches, on_delete: :nilify_all))
      add(:head_ref, :string)
    end

    create(index(:patches, [:bundle_id]))
  end
end
