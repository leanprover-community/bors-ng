defmodule BorsNG.Database.ProjectPermission do
  use Ecto.Type

  @moduledoc """
  A type to represent the permissions of a project member.

  https://docs.github.com/en/rest/collaborators/collaborators?apiVersion=2022-11-28#list-repository-collaborators
  """

  @atom_list [:pull, :triage, :push, :maintain, :admin, nil]
  # keep atom_list_no_nil in sync with synchronize_project_collaborators_by_role/4 in worker/syncer.ex
  # @atom_list_no_nil [:pull, :triage, :push, :maintain, :admin]
  @string_list ["pull", "triage", "push", "maintain", "admin", "nil"]
  @string_list_no_nil ["pull", "triage", "push", "maintain", "admin"]
  @type trepo_perm :: :admin | :maintain | :push | :triage | :pull
  @type tuser_repo_perms :: %{
          admin: boolean,
          maintain: boolean,
          push: boolean,
          triage: boolean,
          pull: boolean
        }

  def type, do: :string

  def select_list,
    do: [
      {"None (manage users manually)", nil},
      {"Admin", :admin},
      {"Maintain", :maintain},
      {"Push", :push},
      {"Triage", :triage},
      {"Pull", :pull}
    ]

  def string_list_no_nil,
    do: @string_list_no_nil

  def cast("") do
    {:ok, nil}
  end

  def cast(data) when data in @string_list do
    {:ok, String.to_atom(data)}
  end

  def cast(data) when data in @atom_list do
    {:ok, data}
  end

  def cast(_), do: :error

  def load(data) do
    cast(data)
  end

  def dump(data) when data in @atom_list do
    {:ok, Atom.to_string(data)}
  end

  def dump(_), do: :error
end
