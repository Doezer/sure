require "test_helper"

class CategoryTest < ActiveSupport::TestCase
  def setup
    @family = families(:dylan_family)
  end

  test "replacing and destroying" do
    transactions = categories(:food_and_drink).transactions.to_a

    categories(:food_and_drink).replace_and_destroy!(categories(:income))

    assert_equal categories(:income), transactions.map { |t| t.reload.category }.uniq.first
  end

  test "replacing with nil should nullify the category" do
    transactions = categories(:food_and_drink).transactions.to_a

    categories(:food_and_drink).replace_and_destroy!(nil)

    assert_nil transactions.map { |t| t.reload.category }.uniq.first
  end

  test "destroying parent category preserves subcategory transaction assignments" do
    parent = @family.categories.create!(
      name: "Parent With Child Transactions",
      color: "#000000",
      lucide_icon: "folder"
    )
    subcategory = @family.categories.create!(
      name: "Child With Transactions",
      color: "#111111",
      lucide_icon: "folder",
      parent: parent
    )
    transaction = Transaction.create!(category: subcategory)

    assert_difference "Category.count", -1 do
      parent.destroy!
    end

    assert_nil subcategory.reload.parent_id
    assert_equal subcategory, transaction.reload.category
  end

  test "invalid parent_id does not raise during validation" do
    category = Category.new(
      name: "Orphan Subcategory",
      color: "#000000",
      lucide_icon: "folder",
      family: @family,
      parent_id: SecureRandom.uuid
    )

    assert_nothing_raised { category.valid? }
    assert_not category.subcategory?
    assert_nil category.parent
  end

  test "subcategory can only be one level deep" do
    category = categories(:subcategory)

    error = assert_raises(ActiveRecord::RecordInvalid) do
      category.subcategories.create!(name: "Invalid category", family: @family)
    end

    assert_equal "Validation failed: Parent can't have more than 2 levels of subcategories", error.message
  end

  test "all_investment_contributions_names returns all locale variants" do
    names = Category.all_investment_contributions_names

    assert_includes names, "Investment Contributions"  # English
    assert_includes names, "Contributions aux investissements"  # French
    assert_includes names, "Investeringsbijdragen"  # Dutch
    assert names.all? { |name| name.is_a?(String) }
    assert_equal names, names.uniq  # No duplicates
  end

  test "display_name localizes default category names" do
    I18n.with_locale(:"zh-CN") do
      assert_equal "餐饮", categories(:food_and_drink).display_name
      assert_equal "未分类", Category.uncategorized.display_name
    end
  end

  test "display_name returns default category names in english" do
    I18n.with_locale(:en) do
      assert_equal "Food & Drink", categories(:food_and_drink).display_name
      assert_equal "Uncategorized", Category.uncategorized.display_name
    end
  end

  test "rejects the reserved Uncategorized filter sentinel as a name" do
    category = Category.new(name: Category::UNCATEGORIZED_FILTER_VALUE, color: "#123456", lucide_icon: "folder", family: @family)

    assert_not category.valid?
    assert_includes category.errors[:name], "is reserved"
  end

  test "filter_value returns the sentinel for the synthetic Uncategorized category and the name for real categories" do
    assert_equal Category::UNCATEGORIZED_FILTER_VALUE, Category.uncategorized.filter_value
    assert_equal categories(:food_and_drink).name, categories(:food_and_drink).filter_value
  end

  test "filter_value stays the sentinel even when read under a different locale than it was built in" do
    # Regression test: filter_value must not rely on a locale-sensitive name
    # comparison (uncategorized? checks name against I18n.t in the *current*
    # locale), or a synthetic instance built under one locale and read under
    # another would silently stop matching.
    synthetic = I18n.with_locale(:"zh-CN") { Category.uncategorized }

    I18n.with_locale(:en) do
      assert_equal Category::UNCATEGORIZED_FILTER_VALUE, synthetic.filter_value
    end
  end

  test "display_name preserves custom category names" do
    category = Category.new(name: "School Supplies", color: "#123456", lucide_icon: "book", family: @family)

    I18n.with_locale(:"zh-CN") do
      assert_equal "School Supplies", category.display_name
    end
  end

  test "display_name_with_parent localizes default parent and child names" do
    category = Category.new(
      name: "Groceries",
      color: "#123456",
      lucide_icon: "shopping-bag",
      family: @family,
      parent: categories(:food_and_drink)
    )

    I18n.with_locale(:"zh-CN") do
      assert_equal "餐饮 > 杂货", category.display_name_with_parent
    end
  end

  test "display_name_with_parent preserves custom child names" do
    category = Category.new(
      name: "Coffee Beans",
      color: "#123456",
      lucide_icon: "coffee",
      family: @family,
      parent: categories(:food_and_drink)
    )

    I18n.with_locale(:"zh-CN") do
      assert_equal "餐饮 > Coffee Beans", category.display_name_with_parent
    end
  end

  test "should accept valid 6-digit hex colors" do
    [ "#FFFFFF", "#000000", "#123456", "#ABCDEF", "#abcdef" ].each do |color|
      category = Category.new(name: "Category #{color}", color: color, lucide_icon: "shapes", family: @family)
      assert category.valid?, "#{color} should be valid"
    end
  end

  test "should reject invalid colors" do
    [ "invalid", "#123", "#1234567", "#GGGGGG", "red", "ffffff", "#ffff", "" ].each do |color|
      category = Category.new(name: "Category #{color}", color: color, lucide_icon: "shapes", family: @family)
      assert_not category.valid?, "#{color} should be invalid"
      assert_includes category.errors[:color], "is invalid"
    end
  end

  test "ids_with_transactions returns a lookup hash for categorized transactions" do
    category = categories(:food_and_drink)
    transaction = Transaction.create!(category: category)
    Entry.create!(
      account: accounts(:depository),
      entryable: transaction,
      name: "Lookup transaction",
      date: Date.current,
      amount: 10,
      currency: "USD"
    )

    lookup = Category.ids_with_transactions(family: @family, category_ids: [ category.id, 0 ])

    assert lookup.key?(category.id)
    assert_not lookup.key?(0)
  end

  test "alphabetically_by_hierarchy orders a category's subcategories immediately after it" do
    ordered = @family.categories.alphabetically_by_hierarchy.to_a

    parent_index = ordered.index(categories(:food_and_drink))
    child_index = ordered.index(categories(:subcategory))

    assert_not_nil parent_index
    assert_not_nil child_index
    assert_equal parent_index + 1, child_index
  end

  test "recently_used_for orders by last_used_at, most recent first" do
    older = categories(:income)
    newer = categories(:food_and_drink)
    older.update!(last_used_at: 2.days.ago)
    newer.update!(last_used_at: 1.day.ago)

    assert_equal [ newer, older ], Category.recently_used_for(family: @family).to_a
  end

  test "recently_used_for excludes categories with no usage yet" do
    categories(:food_and_drink).update!(last_used_at: 1.day.ago)

    assert_not_includes Category.recently_used_for(family: @family).to_a, categories(:income)
  end

  test "recently_used_for excludes given categories and respects limit" do
    a = categories(:income)
    b = categories(:food_and_drink)
    c = categories(:subcategory)
    a.update!(last_used_at: 3.days.ago)
    b.update!(last_used_at: 2.days.ago)
    c.update!(last_used_at: 1.day.ago)

    result = Category.recently_used_for(family: @family, excluding: b, limit: 1)

    assert_equal [ c ], result.to_a
  end

  # --- Account-scoped category sets ---

  test "prime scope returns only family-wide categories" do
    assert_includes @family.categories.prime, categories(:food_and_drink)
    assert_not_includes @family.categories.prime, categories(:account_scoped)
  end

  test "for_account includes prime categories and the account's own" do
    account = accounts(:depository)

    result = @family.categories.for_account(account)

    assert_includes result, categories(:income)
    assert_includes result, categories(:account_scoped)
  end

  test "for_account excludes categories hidden on that account" do
    account = accounts(:depository)

    result = @family.categories.for_account(account)

    assert_not_includes result, categories(:food_and_drink)
  end

  test "for_account on another account still sees the hidden category" do
    other = accounts(:other_asset)

    result = @family.categories.for_account(other)

    assert_includes result, categories(:food_and_drink)
  end

  test "for_account excludes categories scoped to a different account" do
    other = accounts(:other_asset)

    assert_not_includes @family.categories.for_account(other), categories(:account_scoped)
  end

  test "for_account accepts an id as well as a record" do
    account = accounts(:depository)

    assert_equal(
      @family.categories.for_account(account).pluck(:id).sort,
      @family.categories.for_account(account.id).pluck(:id).sort
    )
  end

  test "visible_for_account_ids keeps a category hidden on only some accounts" do
    hidden_on = accounts(:depository)
    visible_on = accounts(:other_asset)

    result = @family.categories.visible_for_account_ids([ hidden_on.id, visible_on.id ])

    assert_includes result, categories(:food_and_drink),
      "a category hidden on one account but not another must survive the union"
  end

  test "visible_for_account_ids drops a category hidden on every account in scope" do
    hidden_on = accounts(:depository)
    also_hidden_on = accounts(:other_asset)
    AccountCategoryOverride.create!(account: also_hidden_on, category: categories(:food_and_drink))

    result = @family.categories.visible_for_account_ids([ hidden_on.id, also_hidden_on.id ])

    assert_not_includes result, categories(:food_and_drink)
  end

  test "visible_for_account_ids with no accounts falls back to the full set" do
    result = @family.categories.visible_for_account_ids([])

    assert_includes result, categories(:food_and_drink)
    assert_includes result, categories(:account_scoped)
  end

  test "visible_for_account_ids excludes categories scoped to accounts out of scope" do
    result = @family.categories.visible_for_account_ids([ accounts(:other_asset).id ])

    assert_not_includes result, categories(:account_scoped)
  end

  test "a prime and an account-scoped category may share a name" do
    scoped = @family.categories.create!(
      name: categories(:food_and_drink).name,
      color: "#000000",
      lucide_icon: "utensils",
      account: accounts(:depository)
    )

    assert scoped.persisted?
  end

  test "two categories on the same account may not share a name" do
    duplicate = @family.categories.build(
      name: categories(:account_scoped).name,
      color: "#000000",
      lucide_icon: "plane",
      account: accounts(:depository)
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:name], "has already been taken"
  end

  test "a category cannot be scoped to an account in another family" do
    foreign_account = accounts(:depository).dup
    foreign_account.family = families(:empty)
    foreign_account.save!(validate: false)

    category = @family.categories.build(
      name: "Foreign", color: "#000000", lucide_icon: "shapes", account: foreign_account
    )

    assert_not category.valid?
    assert_includes category.errors[:account], "must belong to the same family"
  end

  test "a subcategory must share its parent's account scope" do
    child = @family.categories.build(
      name: "Scoped Child",
      color: "#000000",
      lucide_icon: "shapes",
      account: accounts(:depository),
      parent: categories(:food_and_drink)
    )

    assert_not child.valid?
    assert_includes child.errors[:parent], "must be in the same account scope"
  end

  test "hidden_for_account? reports per-account suppression" do
    assert categories(:food_and_drink).hidden_for_account?(accounts(:depository))
    assert_not categories(:food_and_drink).hidden_for_account?(accounts(:other_asset))
  end

  test "hidden_for_account? is false for an account-scoped category" do
    assert_not categories(:account_scoped).hidden_for_account?(accounts(:depository))
  end

  test "bootstrap! creates prime categories even when a scoped one shares the name" do
    family = families(:empty)
    account = family.accounts.create!(
      name: "Bootstrap Account", balance: 0, currency: "USD",
      accountable_type: "Depository", accountable: depositories(:one)
    )
    scoped_name = Category.localized_default_name_for("Income")
    family.categories.create!(
      name: scoped_name, color: "#000000", lucide_icon: "shapes", account: account
    )

    family.categories.bootstrap!

    assert family.categories.prime.exists?(name: scoped_name),
      "bootstrap! must not treat an account-scoped category as the family default"
  end

  test "an override may not target an account-scoped category" do
    override = AccountCategoryOverride.new(
      account: accounts(:depository), category: categories(:account_scoped)
    )

    assert_not override.valid?
    assert_includes override.errors[:category], "must be a family-wide category"
  end
end
