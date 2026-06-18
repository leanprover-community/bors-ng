defmodule BorsNG.Database.Context.Permission do
  @moduledoc """
  Helper commands for user permissions:
  - reviewers
  - members
  - delegation
  """

  use BorsNG.Database.Context

  def list_users_for_project(:member, project_id) do
    Repo.all(
      from(u in User,
        join: l in LinkMemberProject,
        on: true,
        where: l.project_id == ^project_id,
        where: u.id == l.user_id
      )
    )
  end

  def list_users_for_project(:reviewer, project_id) do
    Repo.all(
      from(u in User,
        join: l in LinkUserProject,
        on: true,
        where: l.project_id == ^project_id,
        where: u.id == l.user_id
      )
    )
  end

  def permission?(:member, user, patch) do
    %User{id: user_id} = user
    %Patch{project_id: project_id} = patch

    project_member?(user_id, project_id) or
      permission?(:reviewer, user, patch)
  end

  def permission?(:reviewer, user, patch) do
    %User{id: user_id} = user
    %Patch{id: patch_id, project_id: project_id} = patch

    project_reviewer?(user_id, project_id) or
      patch_delegated_reviewer?(user_id, patch_id)
  end

  def permission?(:none, _, _) do
    true
  end

  def get_permission(nil, _) do
    nil
  end

  def get_permission(user, project) do
    %User{id: user_id} = user
    %Project{id: project_id} = project

    cond do
      project_reviewer?(user_id, project_id) -> :reviewer
      project_member?(user_id, project_id) -> :member
      true -> nil
    end
  end

  defp project_reviewer?(user_id, project_id) do
    LinkUserProject
    |> where([l], l.user_id == ^user_id and l.project_id == ^project_id)
    |> Repo.one()
    |> is_nil()
    # elixirc squawks about unary operators if the module is left off.
    |> Kernel.not()
  end

  defp project_member?(user_id, project_id) do
    LinkMemberProject
    |> where([l], l.user_id == ^user_id and l.project_id == ^project_id)
    |> Repo.one()
    |> is_nil()
    # elixirc squawks about unary operators if the module is left off.
    |> Kernel.not()
  end

  defp patch_delegated_reviewer?(user_id, patch_id) do
    now = NaiveDateTime.utc_now()

    UserPatchDelegation
    |> where(
      [d],
      d.user_id == ^user_id and d.patch_id == ^patch_id and
        (is_nil(d.expires_at) or d.expires_at > ^now)
    )
    |> Repo.all()
    |> Enum.empty?()
    |> Kernel.not()
  end

  @doc """
  Whether the patch currently carries any active (non-expired) delegation,
  regardless of who it's delegated to. Drives the `delegated` label: it stays on
  until the last delegatee is gone. Uses the same lazy-expiry rule as
  `patch_delegated_reviewer?/2`.
  """
  def patch_has_active_delegation?(patch_id) do
    now = NaiveDateTime.utc_now()

    UserPatchDelegation
    |> where(
      [d],
      d.patch_id == ^patch_id and (is_nil(d.expires_at) or d.expires_at > ^now)
    )
    |> Repo.exists?()
  end

  def delegate(user, patch, opts \\ []) do
    expires_at = Keyword.get(opts, :expires_at)
    delegated_at_commit = Keyword.get(opts, :delegated_at_commit)
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    replace_fields = [:expires_at, :delegated_at_commit, :warning_sent_at, :updated_at]

    # MyXQL rejects :conflict_target; ON DUPLICATE KEY UPDATE keys off the
    # (user_id, patch_id) unique index regardless.
    upsert_opts =
      case Repo.__adapter__() do
        Ecto.Adapters.MyXQL ->
          [on_conflict: {:replace, replace_fields}]

        _ ->
          [on_conflict: {:replace, replace_fields}, conflict_target: [:user_id, :patch_id]]
      end

    Repo.insert!(
      %UserPatchDelegation{
        user_id: user.id,
        patch_id: patch.id,
        expires_at: expires_at,
        delegated_at_commit: delegated_at_commit,
        warning_sent_at: nil,
        inserted_at: now,
        updated_at: now
      },
      upsert_opts
    )
  end

  def undelegate(user_id, patch_id) do
    Repo.delete_all(
      from(d in UserPatchDelegation,
        where: d.user_id == ^user_id and d.patch_id == ^patch_id
      )
    )
  end

  def undelegate_patch(patch_id) do
    Repo.delete_all(
      from(d in UserPatchDelegation,
        where: d.patch_id == ^patch_id
      )
    )
  end

  def undelegate_user(user_id) do
    Repo.delete_all(
      from(d in UserPatchDelegation,
        where: d.user_id == ^user_id
      )
    )
  end
end
