require "test_helper"

class AccountCategoryOverrideTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:depository)
    @family = families(:dylan_family)
  end

  test "defaults to hidden" do
    override = AccountCategoryOverride.create!(account: @account, category: categories(:income))

    assert override.hidden?
  end

  test "an account may only override a category once" do
    duplicate = AccountCategoryOverride.new(account: @account, category: categories(:food_and_drink))

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:category_id], "has already been taken"
  end

  test "rejects a category from another family" do
    other_family_category = families(:empty).categories.create!(
      name: "Elsewhere", color: "#000000", lucide_icon: "shapes"
    )

    override = AccountCategoryOverride.new(account: @account, category: other_family_category)

    assert_not override.valid?
    assert_includes override.errors[:category], "must belong to the same family as the account"
  end

  test "rejects an account-scoped category" do
    override = AccountCategoryOverride.new(account: @account, category: categories(:account_scoped))

    assert_not override.valid?
    assert_includes override.errors[:category], "must be a family-wide category"
  end

  test "hidden scope excludes rows explicitly marked visible" do
    override = account_category_overrides(:depository_hides_food)
    override.update!(hidden: false)

    assert_not_includes AccountCategoryOverride.hidden, override
  end

  test "a visible override does not suppress the category" do
    account_category_overrides(:depository_hides_food).update!(hidden: false)

    assert_includes @family.categories.for_account(@account), categories(:food_and_drink)
  end

  test "destroying the category destroys the override" do
    assert_difference -> { AccountCategoryOverride.count }, -1 do
      categories(:food_and_drink).destroy!
    end
  end
end
