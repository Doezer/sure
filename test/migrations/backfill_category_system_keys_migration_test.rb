# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261101120001_backfill_category_system_keys")

# This migration is the one chance to merge the per-locale duplicate "Investment
# Contributions" categories older versions could accumulate.
# Family#investment_contributions_category used to merge them lazily on every
# read; it stops once the key exists, so anything this migration misses becomes
# an unreachable row with transactions still pointing at it.
class BackfillCategorySystemKeysMigrationTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    # test_helper can seed an Investment Contributions category for a family;
    # each test below builds the exact situation it is checking.
    @family.categories.where(name: BackfillCategorySystemKeys::LEGACY_NAMES).destroy_all
    @budget = budgets(:one)
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
    entry = create_transaction(account: @family.accounts.first, category: duplicate)

    run_migration

    assert_equal keeper.id, entry.entryable.reload.category_id,
      "a transaction must never be left pointing at a merged-away category"
  end

  # Ported from the runtime merge this replaces: transactions on every account of
  # the family must be reached, not only the first account's.
  test "moves a duplicate's transactions on every account onto the keeper" do
    keeper = create_legacy("Investment Contributions", created_at: 3.days.ago)
    duplicate = create_legacy("Wpłaty inwestycyjne", created_at: 1.day.ago)
    first = create_transaction(account: accounts(:depository), category: duplicate)
    second = create_transaction(account: accounts(:credit_card), category: duplicate)

    run_migration

    assert_equal keeper.id, first.entryable.reload.category_id
    assert_equal keeper.id, second.entryable.reload.category_id,
      "a transaction on the second account must also be reassigned to the keeper"
  end

  # Report caches are keyed on entries' updated_at; a bare UPDATE of the
  # transaction would leave them serving the old category.
  test "touches the entries of the transactions it reassigns" do
    create_legacy("Investment Contributions", created_at: 3.days.ago)
    duplicate = create_legacy("Contribuições para Investimentos", created_at: 1.day.ago)
    entry = create_transaction(account: accounts(:depository), category: duplicate)
    entry.update_columns(updated_at: 2.days.ago)
    before = entry.reload.updated_at

    run_migration

    assert entry.reload.updated_at > before
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

  test "does not make the keeper its own parent when it sat under the duplicate" do
    duplicate = create_legacy("Contributions aux investissements", created_at: 1.day.ago)
    keeper = @family.categories.create!(
      name: "Investment Contributions", color: "#0d9488", lucide_icon: "trending-up",
      parent: duplicate, created_at: 3.days.ago
    )

    run_migration

    assert_nil keeper.reload.parent_id, "a category must never be its own parent"
    assert_equal "investment_contributions", keeper.system_key
  end

  test "keeps the hierarchy at two levels when the keeper is itself a subcategory" do
    parent = @family.categories.create!(name: "Savings", color: "#000000", lucide_icon: "piggy-bank")
    keeper = @family.categories.create!(
      name: "Investment Contributions", color: "#0d9488", lucide_icon: "trending-up",
      parent: parent, created_at: 3.days.ago
    )
    duplicate = create_legacy("Investeringsbijdragen", created_at: 1.day.ago)
    child = @family.categories.create!(
      name: "Brokerage top-ups", color: "#000000", lucide_icon: "shapes", parent: duplicate
    )

    run_migration

    assert_nil child.reload.parent_id,
      "moving the child under a subcategory would create a third level"
    assert_equal parent.id, keeper.reload.parent_id
  end

  # recurring_transactions.category_id is ON DELETE SET NULL, so deleting the
  # duplicate would silently clear the bill's category.
  test "moves a duplicate's recurring bills onto the keeper" do
    keeper = create_legacy("Investment Contributions", created_at: 3.days.ago)
    duplicate = create_legacy("Contributions aux investissements", created_at: 1.day.ago)
    bill = recurring_transactions(:netflix_subscription)
    bill.update_columns(category_id: duplicate.id)

    run_migration

    assert_equal keeper.id, bill.reload.category_id,
      "deleting the duplicate must not clear the bill's category"
  end

  # Rules hold the category id as text with no foreign key, so a deleted
  # duplicate would leave them pointing at nothing and they would stop matching.
  test "repoints rules that reference a duplicate" do
    keeper = create_legacy("Investment Contributions", created_at: 3.days.ago)
    duplicate = create_legacy("Investeringsbijdragen", created_at: 1.day.ago)
    rule = rules(:one)
    action = rule.actions.build(action_type: "set_transaction_category", value: duplicate.id)
    action.save!(validate: false)
    condition = rule.conditions.build(condition_type: "transaction_category", operator: "=", value: duplicate.id)
    condition.save!(validate: false)

    run_migration

    assert_equal keeper.id, action.reload.value
    assert_equal keeper.id, condition.reload.value
  end

  test "sums the allocations when keeper and duplicate share a budget" do
    keeper = create_legacy("Investment Contributions", created_at: 3.days.ago)
    duplicate = create_legacy("Contributi investimento", created_at: 1.day.ago)
    allocate(keeper => 100, duplicate => 50)

    run_migration

    rows = budget_rows(keeper)
    assert_equal 1, rows.count, "two rows for one (budget, category) would violate the unique index"
    assert_equal 150, rows.first.budgeted_spending, "merging must not silently drop what the user planned to spend"
  end

  # A parent's stored allocation already contains its children's, so summing a
  # parent with its own duplicate-child would count the child twice.
  test "does not double count when the duplicate is a subcategory of the keeper" do
    keeper = create_legacy("Investment Contributions", created_at: 3.days.ago)
    duplicate = @family.categories.create!(
      name: "Contributions aux investissements", color: "#0d9488", lucide_icon: "trending-up",
      parent: keeper, created_at: 1.day.ago
    )
    allocate(keeper => 150, duplicate => 50)

    run_migration

    assert_equal 150, budget_rows(keeper).first.budgeted_spending,
      "the parent's 150 already includes the child's 50"
  end

  test "does not double count when the keeper is a subcategory of the duplicate" do
    duplicate = create_legacy("Contributions aux investissements", created_at: 1.day.ago)
    keeper = @family.categories.create!(
      name: "Investment Contributions", color: "#0d9488", lucide_icon: "trending-up",
      parent: duplicate, created_at: 3.days.ago
    )
    allocate(duplicate => 150, keeper => 50)

    run_migration

    assert_equal 150, budget_rows(keeper).first.budgeted_spending,
      "the parent's 150 already includes the child's 50"
  end

  # A split rule keeps its categories as splits[*].category_id inside one JSON
  # text value, which the exact-match rule updates cannot reach.
  test "repoints categories inside a split rule" do
    keeper = create_legacy("Investment Contributions", created_at: 3.days.ago)
    duplicate = create_legacy("Anlagebeiträge", created_at: 1.day.ago)
    value = { splits: [ { type: "percentage", amount: 100, category_id: duplicate.id } ] }.to_json
    action = rules(:one).actions.build(action_type: "split_transaction", value: value)
    action.save!(validate: false)

    run_migration

    assert_includes action.reload.value, keeper.id
    assert_not_includes action.value, duplicate.id,
      "a deleted category left in a split would silently produce uncategorized splits"
  end

  test "keeps rollover on when only the duplicate had it" do
    keeper = create_legacy("Investment Contributions", created_at: 3.days.ago)
    duplicate = create_legacy("Contributi investimento", created_at: 1.day.ago)
    allocate(keeper => 100, duplicate => 50)
    budget_rows(duplicate).update_all(rollover_enabled: true)

    run_migration

    assert budget_rows(keeper).first.rollover_enabled?,
      "merging must not silently switch off a rollover the user turned on"
  end

  test "hands over a budget row the keeper does not have" do
    keeper = create_legacy("Investment Contributions", created_at: 3.days.ago)
    duplicate = create_legacy("Wpłaty inwestycyjne", created_at: 1.day.ago)
    allocate(duplicate => 50)

    run_migration

    rows = budget_rows(keeper)
    assert_equal 1, rows.count
    assert_equal 50, rows.first.budgeted_spending
  end

  # Repointing every duplicate in one statement would put two rows for the same
  # (budget, category) on the keeper and abort the whole deploy.
  test "merges several duplicates that share a budget the keeper is absent from" do
    keeper = create_legacy("Investment Contributions", created_at: 3.days.ago)
    first = create_legacy("Contributions aux investissements", created_at: 2.days.ago)
    second = create_legacy("Investeringsbijdragen", created_at: 1.day.ago)
    allocate(first => 30, second => 20)

    run_migration

    rows = budget_rows(keeper)
    assert_equal 1, rows.count
    assert_equal 50, rows.first.budgeted_spending
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

    # Gives the budget exactly these categories, each with the amount given.
    def allocate(amounts)
      BudgetCategory.where(budget: @budget, category: amounts.keys).destroy_all

      amounts.each do |category, amount|
        BudgetCategory.create!(budget: @budget, category: category, budgeted_spending: amount, currency: "USD")
      end
    end

    def budget_rows(category)
      BudgetCategory.where(budget: @budget, category: category)
    end

    def run_migration
      ActiveRecord::Migration.suppress_messages do
        BackfillCategorySystemKeys.new.up
      end
    end
end
