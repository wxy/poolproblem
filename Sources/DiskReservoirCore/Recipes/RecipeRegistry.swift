public struct RecipeRegistry {
    public static func builtIn() -> [Recipe] {
        BuiltInRecipes.all
    }
}
