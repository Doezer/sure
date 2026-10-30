# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261030120001_backfill_category_system_keys")

# This migration is the one chance to merge the per-locale duplicate "Investment
# Contributions" categories older versions could accumulate.
# Family#investment_contributions_category used to merge them lazily on every
# read; it stops once the key exists, so anything this migration misses becomes
# an unreachable row with transactions still pointing at it.
class BackfillCategorySystemKeysMigrationTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    # The fixtures and test_helper seed an Investment Contributions category;
    # each test below builds the exact situation it is checking.
    @family.categories.where(name: BackfillCategorySystemKeys::LEGACY_NAMES).destroy_all
    @family.categories.where.not(system_key: nil).update_all(system_key: nil)
  end

  test "stamps the key on an existing category" do
    category = create_legacy("Investment Contributions")

    run_migration

    assert_equal "investment_contributions", category.reload.system_key
  end

  test "recognizes a category created under any supported locale" do
    category = create_legacy("Contributions aux investissements")

    run_migration

    assert_equal "investment_contributions", category.reload.system_key,
      "a family whose row was created under a non-English locale must not be skipped"
  end

  test "keeps the oldest row when a family has duplicates" do
    keeper = create_legacy("Investment Contributions", created_at: 3.days.ago)
    duplicate = create_legacy("Contributions aux investissements", created_at: 1.day.ago)

    run_migration

    assert_equal "investment_contributions", keeper.reload.system_key
    assert_nil Category.find_by(id: duplicate.id), "the duplicate should be merged away"
  end

  test "moves a duplicate's transactions onto the keeper" do
    keeper = create_legacy("Investment Contributions", created_at: 3.days.ago)
    duplicate = create_legacy("Investeringsbijdragen", created_at: 1.day.ago)
    transaction = create_transaction(account: @family.accounts.first)
    transaction.update!(category: duplicate)

    run_migration

    assert_equal keeper.id, transaction.reload.category_id,
      "a transaction must never be left pointing at a merged-away category"
  end

  test "moves a duplicate's subcategories onto the keeper" do
    keeper = create_legacy("Investment Contributions", created_at: 3.days.ago)
    duplicate = create_legacy("Anlagebeiträge", created_at: 1.day.ago)
    child = @family.categories.create!(
      name: "Brokerage top-ups", color: "#000000", lucide_icon: "shapes", parent: duplicate
    )

    run_migration

    assert_equal keeper.id, child.reload.parent_id
  end

  test "does not leave two budget rows for the same budget and category" do
    keeper = create_legacy("Investment Contributions", created_at: 3.days.ago)
    duplicate = create_legacy("Contributi investimento", created_at: 1.day.ago)
    budget = budgets(:one)

    BudgetCategory.where(budget: budget, category: [ keeper, duplicate ]).destroy_all
    BudgetCategory.create!(budget: budget, category: keeper, budgeted_spending: 100, currency: "USD")
    BudgetCategory.create!(budget: budget, category: duplicate, budgeted_spending: 50, currency: "USD")

    run_migration

    assert_equal 1, BudgetCategory.where(budget: budget, category: keeper).count,
      "repointing the duplicate would violate the (budget_id, category_id) index"
  end

  test "repoints a budget row the keeper does not already have" do
    keeper = create_legacy("Investment Contributions", created_at: 3.days.ago)
    duplicate = create_legacy("Wpłaty inwestycyjne", created_at: 1.day.ago)
    budget = budgets(:one)

    BudgetCategory.where(budget: budget, category: [ keeper, duplicate ]).destroy_all
    BudgetCategory.create!(budget: budget, category: duplicate, budgeted_spending: 50, currency: "USD")

    run_migration

    assert_equal 1, BudgetCategory.where(budget: budget, category: keeper).count,
      "the duplicate's allocation should survive on the keeper"
  end

  test "leaves ordinary categories alone" do
    run_migration

    assert_nil categories(:food_and_drink).reload.system_key
  end

  test "is re-runnable" do
    category = create_legacy("Investment Contributions")

    run_migration
    run_migration

    assert_equal "investment_contributions", category.reload.system_key
    assert_equal 1, @family.categories.where(system_key: "investment_contributions").count
  end

  test "skips a family that already has a stamped category" do
    already_stamped = create_legacy("Investment Contributions")
    already_stamped.update_columns(system_key: "investment_contributions")
    other = create_legacy("Contributions aux investissements")

    run_migration

    assert_equal "investment_contributions", already_stamped.reload.system_key
    assert_nil other.reload.system_key,
      "a second row must not be stamped into a family that already has one"
  end

  private
    def create_legacy(name, created_at: Time.current)
      @family.categories.create!(
        name: name,
        color: "#0d9488",
        lucide_icon: "trending-up",
        created_at: created_at
      )
    end

    def run_migration
      ActiveRecord::Migration.suppress_messages do
        BackfillCategorySystemKeys.new.up
      end
    end
end
