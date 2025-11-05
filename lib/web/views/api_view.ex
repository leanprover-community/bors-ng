defmodule BorsNG.ApiView do
  @moduledoc """
  JSON renderers for API responses.
  """

  use BorsNG.Web, :view

  def render("active_batches.json", %{batch_ids: ids}) do
    %{batch_ids: ids}
  end
end
