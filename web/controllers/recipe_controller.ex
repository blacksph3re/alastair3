defmodule Alastair.RecipeController do
  use Alastair.Web, :controller

  import Alastair.Helper
  alias Alastair.Recipe
  alias Alastair.RecipeIngredient

  def index(conn, params) do
    recipes = from(p in Recipe, 
      where: p.published == true,
      order_by: :name)
    |> paginate(params)
    |> search(params)
    |> Repo.all
    
    render(conn, "index.json", recipes: recipes)
  end

  def index_mine(conn, _params) do
    recipes = from(p in Recipe, where: p.created_by == ^conn.assigns.user.id) |> Repo.all()
    render(conn, "index.json", recipes: recipes)
  end

  defp create_recipe_ingredient(recipe_id, ingredient_id, quantity) do
    changeset = RecipeIngredient.changeset(%RecipeIngredient{}, %{recipe_id: recipe_id, ingredient_id: ingredient_id, quantity: quantity})
    # TODO add error handling
    Repo.insert!(changeset)
  end

  defp reset_recipe_ingredients(recipe, recipes_ingredients) do
    from(p in RecipeIngredient, where: p.recipe_id == ^recipe.id) |> Repo.delete_all

    recipes_ingredients
    |> Enum.uniq_by(fn(x) -> x["ingredient_id"] end) # TODO merge duplicate ingredients into one
    |> Enum.map(fn(x) -> create_recipe_ingredient(recipe.id, x["ingredient_id"], x["quantity"]) end)
  end

  def create(conn, %{"recipe" => recipe_params}) do
    changeset = Recipe.changeset(%Recipe{created_by: conn.assigns.user.id}, recipe_params)

    case Repo.insert(changeset) do
      {:ok, recipe} ->

        # Store the id as root_version_id, as we are the root ourselves
        recipe = recipe
        |> Recipe.changeset
        |> Ecto.Changeset.force_change(:root_version_id, recipe.id)
        |> Repo.update!

        # If there are ingredients, add them
        if Map.get(recipe_params, "recipes_ingredients", nil) != nil do
          reset_recipe_ingredients(recipe, recipe_params["recipes_ingredients"])
        end

        # To properly display the results, preload everything
        recipe = Repo.preload(recipe, [{:recipes_ingredients, [{:ingredient, [:default_measurement]}]}], force: true)

        conn
        |> put_status(:created)
        |> put_resp_header("location", recipe_path(conn, :show, recipe))
        |> render("show.json", recipe: recipe)
      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(Alastair.ChangesetView, "error.json", changeset: changeset)
    end
  end

  def show(conn, %{"id" => id}) do
    recipe = Repo.get!(Recipe, id)
      |> Repo.preload([{:recipes_ingredients, [{:ingredient, [:default_measurement]}]}]) # Preload nested recipe_ingredient and ingredient and measurement
    render(conn, "show.json", recipe: recipe)
  end

  # An unpublished recipe can be edited directly
  defp update_unpublished(conn, recipe, recipe_params) do
    changeset = Recipe.changeset(recipe, recipe_params)

    # Check if this is the newest version, otherwise refuse the request
    max_version = from(p in Recipe, where: p.root_version_id == ^recipe.root_version_id) |> Repo.all
    |> Enum.map(fn(x) -> x.version end)
    |> Enum.max(fn -> 0 end)

    if max_version <= recipe.version do
      case Repo.update(changeset) do
        {:ok, recipe} ->
          # Delete all ingredients and add all again
          if Map.get(recipe_params, "recipes_ingredients", nil) != nil do
            reset_recipe_ingredients(recipe, recipe_params["recipes_ingredients"])
          end
          recipe = Repo.preload(recipe, [{:recipes_ingredients, [{:ingredient, [:default_measurement]}]}], force: true)

          render(conn, "show.json", recipe: recipe)
        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> render(Alastair.ChangesetView, "error.json", changeset: changeset)
      end
    else
      conn
      |> put_status(:method_not_allowed)
      |> render(Alastair.ErrorView, "error.json", message: "You can only edit the most recent version of a recipe")
    end
  end

  # An update to a published recipe creates a new version
  defp update_published(conn, old_recipe, recipe_params) do

    changeset = old_recipe
    |> Recipe.duplicate
    |> Recipe.changeset(recipe_params)

    # Set the published state of the old version to "unpublished" so it doesn't appear in listings anymore
    old_recipe
    |> Recipe.changeset
    |> Ecto.Changeset.force_change(:published, false)
    |> Repo.update!

    case Repo.insert(changeset) do
      {:ok, recipe} ->

        # Either use the recipes_ingredients from the request if present or otherwise copy over the old ones
        if Map.get(recipe_params, "recipes_ingredients", nil) != nil do
          reset_recipe_ingredients(recipe, recipe_params["recipes_ingredients"])
        else
          old_recipe.recipes_ingredients
          |> Enum.map(fn(x) -> create_recipe_ingredient(recipe.id, x.ingredient_id, x.quantity) end)
        end

        recipe = Repo.preload(recipe, [{:recipes_ingredients, [{:ingredient, [:default_measurement]}]}], force: true)

        render(conn, "show.json", recipe: recipe)
      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(Alastair.ChangesetView, "error.json", changeset: changeset)
    end
  end

  def update(conn, %{"id" => id, "recipe" => recipe_params}) do
    # Transaction is needed because old recipe and new recipe should be updated atomically
    case Repo.transaction(fn ->
      recipe = from(p in Recipe, where: p.id == ^id, preload: [:recipes_ingredients]) |> Repo.one!
      # Only the user who created the recipe can still edit it
      if recipe.created_by != conn.assigns.user.id && !conn.assigns.user.superadmin do
        conn
        |> put_status(:method_not_allowed)
        |> render(Alastair.ErrorView, "error.json", message: "Only the original author of a recipe can edit it")
      else
        if recipe.published do
          update_published(conn, recipe, recipe_params)
        else
          update_unpublished(conn, recipe, recipe_params)
        end
      end
    end) do
      {:ok, conn} ->
        conn
      _ ->
        conn
        |> put_status(:internal_server_error)
        |> render(Alastair.ErrorView, "error.json", message: "Something went wrong inside the transaction")
    end
  end

  def delete(conn, %{"id" => id}) do
    recipe = Repo.get!(Recipe, id) 

    if recipe.published do
      conn
      |> put_status(:method_not_allowed)
      |> render(Alastair.ErrorView, "error.json", message: "You can not delete a published recipe")
    else
      if recipe.created_by != conn.assigns.user.id do
        conn
        |> put_status(:method_not_allowed)
        |> render(Alastair.ErrorView, "error.json", message: "You can not delete a recipe which is not yours")
      else
        recipe |> Repo.delete!

        from(p in Alastair.RecipeIngredient, where: p.recipe_id == ^id) |> Repo.delete_all
        from(p in Alastair.Review, where: p.recipe_id == ^id) |> Repo.delete_all
        from(p in Alastair.MealRecipe, where: p.recipe_id == ^id) |> Repo.delete_all # Should not exist yet, just to make sure
        send_resp(conn, :no_content, "")
      end
    end
  end

  defp calc_avg_review(id) do
    tmp = from(p in Alastair.Review, where: p.recipe_id == ^id) 
    |> Repo.all
    |> Enum.reduce({0, 0}, fn(x, acc) -> {elem(acc, 0) + x.rating, elem(acc, 1) + 1} end)

    case elem(tmp, 1) do
      0 -> nil
      _ -> elem(tmp, 0) / elem(tmp, 1)
    end
  end

  def update_avg_review(id) do
    review = calc_avg_review(id)
    Repo.get!(Recipe, id)
    |> Ecto.Changeset.change(avg_review: review)
    |> Repo.update!
  end
end
