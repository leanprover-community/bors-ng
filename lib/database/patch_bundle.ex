defmodule BorsNG.Database.PatchBundle do
  @moduledoc """
  A group of patches that must merge atomically.

  Every member enters the same batch and leaves the queue together. Bisection
  never separates them. Canceling or failing one member pulls all of them.
  Membership is recorded on the patch itself (`Patch.bundle_id`). This table
  exists so a bundle has a stable identity and is cleaned up with its project.
  """

  use BorsNG.Database.Model

  @type t :: %__MODULE__{}
  @type id :: pos_integer

  schema "patch_bundles" do
    belongs_to(:project, Project)
    has_many(:patches, Patch, foreign_key: :bundle_id)
    timestamps()
  end

  def new(project_id) do
    %__MODULE__{project_id: project_id}
  end

  def changeset(struct, params \\ %{}) do
    struct
    |> cast(params, [:project_id])
    |> validate_required([:project_id])
  end
end
