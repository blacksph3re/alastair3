defmodule Alastair.ShoppingItemController do
  use Alastair.Web, :controller

  alias Alastair.ShoppingItem

  def index(conn, %{"shop_id" => shop_id}) do
    shopping_items = from(p in ShoppingItem, where: p.shop_id == ^shop_id) |> Repo.all
    render(conn, "index.json", shopping_items: shopping_items)
  end

  def create(conn, %{"shopping_item" => shopping_item_params, "shop_id" => shop_id}) do
    shopping_item_params = Map.put(shopping_item_params, "shop_id", shop_id)
    changeset = ShoppingItem.changeset(%ShoppingItem{}, shopping_item_params)

    case Repo.insert(changeset) do
      {:ok, shopping_item} ->
        shopping_item = Repo.preload(shopping_item, [:mapped_ingredient])

        conn
        |> put_status(:created)
        |> put_resp_header("location", shop_shopping_item_path(conn, :show, shop_id, shopping_item))
        |> render("show.json", shopping_item: shopping_item)
      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(Alastair.ChangesetView, "error.json", changeset: changeset)
    end
  end

  def show(conn, %{"id" => id}) do
    shopping_item = Repo.get!(ShoppingItem, id)
    |> Repo.preload([:mapped_ingredient])

    render(conn, "show.json", shopping_item: shopping_item)
  end

  def update(conn, %{"id" => id, "shopping_item" => shopping_item_params, "shop_id" => shop_id}) do
    shopping_item = Repo.get!(ShoppingItem, id)
    changeset = ShoppingItem.changeset(shopping_item, Map.put(shopping_item_params, "shop_id", shop_id))

    case Repo.update(changeset) do
      {:ok, shopping_item} ->
        shopping_item = Repo.preload(shopping_item, [:mapped_ingredient])

        render(conn, "show.json", shopping_item: shopping_item)
      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(Alastair.ChangesetView, "error.json", changeset: changeset)
    end
  end

  def delete(conn, %{"id" => id}) do
    shopping_item = Repo.get!(ShoppingItem, id)

    # Here we use delete! (with a bang) because we expect
    # it to always work (and if it does not, it will raise).
    Repo.delete!(shopping_item)

    send_resp(conn, :no_content, "")
  end
end