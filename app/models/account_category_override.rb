# A family's decision to suppress one prime category on one account.
#
# Only prime categories (account_id NULL) can be overridden: an account-scoped
# category already belongs to exactly one account, so hiding it there would be
# indistinguishable from deleting it.
class AccountCategoryOverride < ApplicationRecord
  belongs_to :account
  belongs_to :category

  validates :category_id, uniqueness: { scope: :account_id }
  validate :category_is_prime
  validate :category_in_same_family

  scope :hidden, -> { where(hidden: true) }

  private
    def category_is_prime
      return if category.nil?

      errors.add(:category, "must be a family-wide category") if category.account_id.present?
    end

    def category_in_same_family
      return if category.nil? || account.nil?

      errors.add(:category, "must belong to the same family as the account") if category.family_id != account.family_id
    end
end
