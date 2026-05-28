defmodule BorsNG.Database.Repo.Migrations.AddDelegationExpiry do
  use Ecto.Migration
  import Ecto.Query

  def up do
    alter table(:user_patch_delegations) do
      add(:expires_at, :naive_datetime)
      add(:delegated_at_commit, :string)
      add(:warning_sent_at, :naive_datetime)
    end

    flush()

    dedupe_existing_delegations()

    create(index(:user_patch_delegations, [:expires_at]))

    create(
      unique_index(:user_patch_delegations, [:user_id, :patch_id],
        name: :user_patch_delegation_user_id_patch_id_index
      )
    )
  end

  def down do
    drop_if_exists(
      unique_index(:user_patch_delegations, [:user_id, :patch_id],
        name: :user_patch_delegation_user_id_patch_id_index
      )
    )

    drop_if_exists(index(:user_patch_delegations, [:expires_at]))

    alter table(:user_patch_delegations) do
      remove(:warning_sent_at)
      remove(:delegated_at_commit)
      remove(:expires_at)
    end
  end

  defp dedupe_existing_delegations do
    # For each (user_id, patch_id) keep the row with the highest id; delete the rest.
    rows =
      repo().all(
        from(d in "user_patch_delegations",
          select: {d.id, d.user_id, d.patch_id},
          order_by: [asc: d.id]
        )
      )

    ids_to_keep =
      rows
      |> Enum.group_by(fn {_id, uid, pid} -> {uid, pid} end)
      |> Enum.map(fn {_key, group} ->
        {id, _, _} = List.last(group)
        id
      end)

    if ids_to_keep != [] do
      repo().delete_all(
        from(d in "user_patch_delegations", where: d.id not in ^ids_to_keep)
      )
    end
  end
end
