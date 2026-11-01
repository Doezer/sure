# frozen_string_literal: true

class AddSystemKeyToCategories < ActiveRecord::Migration[8.1]
  def change
    add_column :categories, :system_key, :string, null: true, default: nil

    # Safe to create before BackfillCategorySystemKeys runs: every existing row
    # has a NULL system_key, so the partial index starts empty, and the backfill
    # stamps exactly one row per family.
    add_index :categories, [ :family_id, :system_key ],
              unique: true,
              where: "system_key IS NOT NULL",
              name: "index_categories_on_family_id_and_system_key"
  end
end
