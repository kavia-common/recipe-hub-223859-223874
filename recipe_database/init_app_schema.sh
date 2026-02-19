#!/bin/bash
set -euo pipefail

# Recipe Hub - PostgreSQL schema + seed initializer
# Idempotent: safe to run multiple times.
#
# Notes:
# - Uses the connection string in db_connection.txt (required by container rules).
# - Executes DDL/DML statements one at a time via psql -c "...".
# - Avoids requiring extensions not guaranteed to exist.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONN_CMD_FILE="${SCRIPT_DIR}/db_connection.txt"

if [ ! -f "${CONN_CMD_FILE}" ]; then
  echo "ERROR: db_connection.txt not found at ${CONN_CMD_FILE}"
  echo "This script must be run after startup.sh writes db_connection.txt"
  exit 1
fi

# db_connection.txt contains: psql postgresql://user:pass@host:port/db
PSQL_BASE="$(cat "${CONN_CMD_FILE}")"

exec_psql() {
  local sql="$1"
  # Execute one statement per call (per container rules).
  ${PSQL_BASE} -v ON_ERROR_STOP=1 -c "${sql}"
}

echo "Initializing Recipe Hub schema..."

# Core tables
exec_psql "CREATE TABLE IF NOT EXISTS app_users (
  id BIGSERIAL PRIMARY KEY,
  email TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,
  display_name TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);"

exec_psql "CREATE TABLE IF NOT EXISTS recipes (
  id BIGSERIAL PRIMARY KEY,
  author_user_id BIGINT REFERENCES app_users(id) ON DELETE SET NULL,
  title TEXT NOT NULL,
  description TEXT,
  prep_time_minutes INT NOT NULL DEFAULT 0,
  cook_time_minutes INT NOT NULL DEFAULT 0,
  servings INT NOT NULL DEFAULT 1,
  image_url TEXT,
  is_public BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);"

exec_psql "CREATE INDEX IF NOT EXISTS idx_recipes_author_user_id ON recipes(author_user_id);"
exec_psql "CREATE INDEX IF NOT EXISTS idx_recipes_is_public ON recipes(is_public);"
exec_psql "CREATE INDEX IF NOT EXISTS idx_recipes_title ON recipes(title);"

exec_psql "CREATE TABLE IF NOT EXISTS recipe_ingredients (
  id BIGSERIAL PRIMARY KEY,
  recipe_id BIGINT NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
  position INT NOT NULL DEFAULT 0,
  name TEXT NOT NULL,
  quantity TEXT,
  unit TEXT,
  notes TEXT
);"

exec_psql "CREATE INDEX IF NOT EXISTS idx_recipe_ingredients_recipe_id ON recipe_ingredients(recipe_id);"

exec_psql "CREATE TABLE IF NOT EXISTS recipe_steps (
  id BIGSERIAL PRIMARY KEY,
  recipe_id BIGINT NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
  step_number INT NOT NULL,
  instruction TEXT NOT NULL
);"

exec_psql "CREATE UNIQUE INDEX IF NOT EXISTS uq_recipe_steps_recipe_step_number ON recipe_steps(recipe_id, step_number);"
exec_psql "CREATE INDEX IF NOT EXISTS idx_recipe_steps_recipe_id ON recipe_steps(recipe_id);"

# Tags
exec_psql "CREATE TABLE IF NOT EXISTS tags (
  id BIGSERIAL PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);"

exec_psql "CREATE TABLE IF NOT EXISTS recipe_tags (
  recipe_id BIGINT NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
  tag_id BIGINT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  PRIMARY KEY (recipe_id, tag_id)
);"

exec_psql "CREATE INDEX IF NOT EXISTS idx_recipe_tags_tag_id ON recipe_tags(tag_id);"

# Favorites
exec_psql "CREATE TABLE IF NOT EXISTS favorites (
  user_id BIGINT NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  recipe_id BIGINT NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, recipe_id)
);"

exec_psql "CREATE INDEX IF NOT EXISTS idx_favorites_recipe_id ON favorites(recipe_id);"

# Shopping lists
exec_psql "CREATE TABLE IF NOT EXISTS shopping_lists (
  id BIGSERIAL PRIMARY KEY,
  user_id BIGINT NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);"

exec_psql "CREATE INDEX IF NOT EXISTS idx_shopping_lists_user_id ON shopping_lists(user_id);"

exec_psql "CREATE TABLE IF NOT EXISTS shopping_list_items (
  id BIGSERIAL PRIMARY KEY,
  shopping_list_id BIGINT NOT NULL REFERENCES shopping_lists(id) ON DELETE CASCADE,
  position INT NOT NULL DEFAULT 0,
  item_name TEXT NOT NULL,
  quantity TEXT,
  unit TEXT,
  notes TEXT,
  is_checked BOOLEAN NOT NULL DEFAULT FALSE,
  source_recipe_id BIGINT REFERENCES recipes(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);"

exec_psql "CREATE INDEX IF NOT EXISTS idx_shopping_list_items_list_id ON shopping_list_items(shopping_list_id);"

# Optional helper view (useful for browsing)
exec_psql "CREATE OR REPLACE VIEW v_recipe_summary AS
SELECT
  r.id,
  r.title,
  r.description,
  r.prep_time_minutes,
  r.cook_time_minutes,
  r.servings,
  r.image_url,
  r.is_public,
  r.created_at,
  r.updated_at,
  u.id AS author_id,
  u.display_name AS author_display_name,
  u.email AS author_email
FROM recipes r
LEFT JOIN app_users u ON u.id = r.author_user_id;"

echo "Seeding Recipe Hub data (idempotent)..."

# Seed users (password hashes are placeholders; backend should create real hashes)
exec_psql "INSERT INTO app_users (email, password_hash, display_name)
VALUES ('demo@recipehub.local', 'demo-password-hash', 'Demo User')
ON CONFLICT (email) DO UPDATE SET display_name = EXCLUDED.display_name;"

exec_psql "INSERT INTO app_users (email, password_hash, display_name)
VALUES ('chef@recipehub.local', 'chef-password-hash', 'Chef Alex')
ON CONFLICT (email) DO UPDATE SET display_name = EXCLUDED.display_name;"

# Seed tags
exec_psql "INSERT INTO tags (name) VALUES ('Vegetarian') ON CONFLICT (name) DO NOTHING;"
exec_psql "INSERT INTO tags (name) VALUES ('Quick') ON CONFLICT (name) DO NOTHING;"
exec_psql "INSERT INTO tags (name) VALUES ('Comfort Food') ON CONFLICT (name) DO NOTHING;"
exec_psql "INSERT INTO tags (name) VALUES ('Dessert') ON CONFLICT (name) DO NOTHING;"
exec_psql "INSERT INTO tags (name) VALUES ('Gluten-Free') ON CONFLICT (name) DO NOTHING;"

# Seed recipes (stable titles)
exec_psql "INSERT INTO recipes (author_user_id, title, description, prep_time_minutes, cook_time_minutes, servings, image_url, is_public)
SELECT u.id, 'Classic Tomato Pasta', 'Simple pantry pasta with a bright tomato sauce.', 10, 20, 2, NULL, TRUE
FROM app_users u
WHERE u.email = 'chef@recipehub.local'
AND NOT EXISTS (SELECT 1 FROM recipes r WHERE r.title = 'Classic Tomato Pasta');"

exec_psql "INSERT INTO recipes (author_user_id, title, description, prep_time_minutes, cook_time_minutes, servings, image_url, is_public)
SELECT u.id, 'Overnight Oats', 'No-cook breakfast with oats, milk, and toppings.', 5, 0, 1, NULL, TRUE
FROM app_users u
WHERE u.email = 'demo@recipehub.local'
AND NOT EXISTS (SELECT 1 FROM recipes r WHERE r.title = 'Overnight Oats');"

exec_psql "INSERT INTO recipes (author_user_id, title, description, prep_time_minutes, cook_time_minutes, servings, image_url, is_public)
SELECT u.id, 'One-Bowl Chocolate Mug Cake', 'Fast dessert in a mug.', 5, 2, 1, NULL, TRUE
FROM app_users u
WHERE u.email = 'demo@recipehub.local'
AND NOT EXISTS (SELECT 1 FROM recipes r WHERE r.title = 'One-Bowl Chocolate Mug Cake');"

# Seed ingredients/steps for Tomato Pasta
exec_psql "INSERT INTO recipe_ingredients (recipe_id, position, name, quantity, unit, notes)
SELECT r.id, 1, 'Spaghetti', '200', 'g', NULL FROM recipes r
WHERE r.title = 'Classic Tomato Pasta'
AND NOT EXISTS (SELECT 1 FROM recipe_ingredients i WHERE i.recipe_id = r.id AND i.position = 1);"

exec_psql "INSERT INTO recipe_ingredients (recipe_id, position, name, quantity, unit, notes)
SELECT r.id, 2, 'Canned tomatoes', '1', 'can', 'Crushed or whole' FROM recipes r
WHERE r.title = 'Classic Tomato Pasta'
AND NOT EXISTS (SELECT 1 FROM recipe_ingredients i WHERE i.recipe_id = r.id AND i.position = 2);"

exec_psql "INSERT INTO recipe_ingredients (recipe_id, position, name, quantity, unit, notes)
SELECT r.id, 3, 'Garlic', '2', 'cloves', 'Minced' FROM recipes r
WHERE r.title = 'Classic Tomato Pasta'
AND NOT EXISTS (SELECT 1 FROM recipe_ingredients i WHERE i.recipe_id = r.id AND i.position = 3);"

exec_psql "INSERT INTO recipe_ingredients (recipe_id, position, name, quantity, unit, notes)
SELECT r.id, 4, 'Olive oil', '1', 'tbsp', NULL FROM recipes r
WHERE r.title = 'Classic Tomato Pasta'
AND NOT EXISTS (SELECT 1 FROM recipe_ingredients i WHERE i.recipe_id = r.id AND i.position = 4);"

exec_psql "INSERT INTO recipe_steps (recipe_id, step_number, instruction)
SELECT r.id, 1, 'Boil salted water and cook pasta until al dente.' FROM recipes r
WHERE r.title = 'Classic Tomato Pasta'
AND NOT EXISTS (SELECT 1 FROM recipe_steps s WHERE s.recipe_id = r.id AND s.step_number = 1);"

exec_psql "INSERT INTO recipe_steps (recipe_id, step_number, instruction)
SELECT r.id, 2, 'Sauté garlic in olive oil for 30 seconds, add tomatoes, simmer 10 minutes.' FROM recipes r
WHERE r.title = 'Classic Tomato Pasta'
AND NOT EXISTS (SELECT 1 FROM recipe_steps s WHERE s.recipe_id = r.id AND s.step_number = 2);"

exec_psql "INSERT INTO recipe_steps (recipe_id, step_number, instruction)
SELECT r.id, 3, 'Toss pasta with sauce, adjust seasoning, serve.' FROM recipes r
WHERE r.title = 'Classic Tomato Pasta'
AND NOT EXISTS (SELECT 1 FROM recipe_steps s WHERE s.recipe_id = r.id AND s.step_number = 3);"

# Tag Tomato Pasta: Quick + Comfort Food
exec_psql "INSERT INTO recipe_tags (recipe_id, tag_id)
SELECT r.id, t.id
FROM recipes r, tags t
WHERE r.title = 'Classic Tomato Pasta' AND t.name = 'Quick'
AND NOT EXISTS (SELECT 1 FROM recipe_tags rt WHERE rt.recipe_id = r.id AND rt.tag_id = t.id);"

exec_psql "INSERT INTO recipe_tags (recipe_id, tag_id)
SELECT r.id, t.id
FROM recipes r, tags t
WHERE r.title = 'Classic Tomato Pasta' AND t.name = 'Comfort Food'
AND NOT EXISTS (SELECT 1 FROM recipe_tags rt WHERE rt.recipe_id = r.id AND rt.tag_id = t.id);"

# Overnight oats: Vegetarian + Quick + Gluten-Free (if using GF oats)
exec_psql "INSERT INTO recipe_ingredients (recipe_id, position, name, quantity, unit, notes)
SELECT r.id, 1, 'Rolled oats', '1/2', 'cup', NULL FROM recipes r
WHERE r.title = 'Overnight Oats'
AND NOT EXISTS (SELECT 1 FROM recipe_ingredients i WHERE i.recipe_id = r.id AND i.position = 1);"

exec_psql "INSERT INTO recipe_ingredients (recipe_id, position, name, quantity, unit, notes)
SELECT r.id, 2, 'Milk (or dairy-free)', '1/2', 'cup', NULL FROM recipes r
WHERE r.title = 'Overnight Oats'
AND NOT EXISTS (SELECT 1 FROM recipe_ingredients i WHERE i.recipe_id = r.id AND i.position = 2);"

exec_psql "INSERT INTO recipe_steps (recipe_id, step_number, instruction)
SELECT r.id, 1, 'Mix oats and milk in a jar. Add toppings. Refrigerate overnight.' FROM recipes r
WHERE r.title = 'Overnight Oats'
AND NOT EXISTS (SELECT 1 FROM recipe_steps s WHERE s.recipe_id = r.id AND s.step_number = 1);"

exec_psql "INSERT INTO recipe_tags (recipe_id, tag_id)
SELECT r.id, t.id
FROM recipes r, tags t
WHERE r.title = 'Overnight Oats' AND t.name = 'Quick'
AND NOT EXISTS (SELECT 1 FROM recipe_tags rt WHERE rt.recipe_id = r.id AND rt.tag_id = t.id);"

exec_psql "INSERT INTO recipe_tags (recipe_id, tag_id)
SELECT r.id, t.id
FROM recipes r, tags t
WHERE r.title = 'Overnight Oats' AND t.name = 'Vegetarian'
AND NOT EXISTS (SELECT 1 FROM recipe_tags rt WHERE rt.recipe_id = r.id AND rt.tag_id = t.id);"

# Mug cake: Dessert
exec_psql "INSERT INTO recipe_tags (recipe_id, tag_id)
SELECT r.id, t.id
FROM recipes r, tags t
WHERE r.title = 'One-Bowl Chocolate Mug Cake' AND t.name = 'Dessert'
AND NOT EXISTS (SELECT 1 FROM recipe_tags rt WHERE rt.recipe_id = r.id AND rt.tag_id = t.id);"

# Seed one shopping list for demo user
exec_psql "INSERT INTO shopping_lists (user_id, name)
SELECT u.id, 'Weekly Groceries'
FROM app_users u
WHERE u.email = 'demo@recipehub.local'
AND NOT EXISTS (
  SELECT 1 FROM shopping_lists sl
  WHERE sl.user_id = u.id AND sl.name = 'Weekly Groceries'
);"

# Seed one shopping list item
exec_psql "INSERT INTO shopping_list_items (shopping_list_id, position, item_name, quantity, unit, notes, is_checked)
SELECT sl.id, 1, 'Bananas', '2', NULL, NULL, FALSE
FROM shopping_lists sl
JOIN app_users u ON u.id = sl.user_id
WHERE u.email = 'demo@recipehub.local'
AND sl.name = 'Weekly Groceries'
AND NOT EXISTS (
  SELECT 1 FROM shopping_list_items i
  WHERE i.shopping_list_id = sl.id AND i.position = 1
);"

# Favorite: demo user favorites Tomato Pasta
exec_psql "INSERT INTO favorites (user_id, recipe_id)
SELECT u.id, r.id
FROM app_users u, recipes r
WHERE u.email = 'demo@recipehub.local'
AND r.title = 'Classic Tomato Pasta'
AND NOT EXISTS (
  SELECT 1 FROM favorites f WHERE f.user_id = u.id AND f.recipe_id = r.id
);"

echo "Recipe Hub schema + seed complete."
