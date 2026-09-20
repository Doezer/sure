class AddAccountToCategories < ActiveRecord::Migration[8.1]
  def change
    # NULL means "prime": a category that applies to every account, which is
    # what every category is today. A non-NULL account_id scopes the category
    # to that single account. Nullable and not backfilled on purpose -- every
    # existing row stays prime, so the default behaviour is unchanged.
    add_reference :categories, :account, type: :uuid, null: true, index: true
    add_foreign_key :categories, :accounts, column: :account_id, on_delete: :cascade

    # Names only have to be unique within their own scope: a family may now
    # have a prime "Travel" and an account-scoped "Travel" on the pro account.
    # Postgres treats NULLs as distinct, so a single index over
    # (family_id, account_id, name) would not constrain prime categories at
    # all -- hence two partial indexes rather than one.
    remove_index :categories, column: [ :family_id, :name ], unique: true, name: "index_categories_on_family_id_and_name"

    add_index :categories, [ :family_id, :name ],
              unique: true,
              where: "account_id IS NULL",
              name: "index_categories_on_family_id_and_name_prime"

    add_index :categories, [ :family_id, :account_id, :name ],
              unique: true,
              where: "account_id IS NOT NULL",
              name: "index_categories_on_family_id_and_account_id_and_name"
  end
end
