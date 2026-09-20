class CreateAccountCategoryOverrides < ActiveRecord::Migration[8.1]
  def change
    # One row per (account, prime category) the family has chosen to suppress
    # on that account. Absence of a row means visible, so an account with no
    # overrides resolves to exactly the family category list it sees today.
    #
    # `hidden` is a column rather than being implied by the row's existence so
    # that a later per-account preference (pinning, ordering) has somewhere to
    # live without another table.
    create_table :account_category_overrides, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :account, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :category, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.boolean :hidden, null: false, default: true

      t.timestamps
    end

    add_index :account_category_overrides, [ :account_id, :category_id ], unique: true
    add_index :account_category_overrides, [ :account_id, :hidden ]
  end
end
