# frozen_string_literal: true

# Stamps `system_key` on each family's existing "Investment Contributions"
# category, and collapses the per-locale duplicates older versions could
# accumulate.
#
# Family#investment_contributions_category used to find that category by
# comparing its name against every supported locale, de-duplicate whatever it
# found, and rename the survivor -- on every call. It stops doing all of that
# once this migration has run, so a family left holding two of those rows would
# have one of them become unreachable. This is the one chance to merge them.
#
# Re-runnable: a family that already has a stamped row is skipped.
class BackfillCategorySystemKeys < ActiveRecord::Migration[8.1]
  SYSTEM_KEY_INVESTMENT_CONTRIBUTIONS = "investment_contributions"

  # Static snapshot of every localized spelling the category could have been
  # created under, taken when this migration shipped. Inlined rather than read
  # through I18n or Category, for the same reason
  # BackfillInvestmentContributionCategories inlines its own list: a migration's
  # behaviour must not change when a translation is corrected or a locale is
  # added later. Locales with no category translation file fall back to English,
  # which is in this list.
  LEGACY_NAMES = [
    "Investment Contributions",
    "Contributions aux investissements",
    "Contribucions d'inversió",
    "Investeringsbijdragen",
    "Anlagebeiträge",
    "Aportaciones a inversiones",
    "Befektetési befizetések",
    "Contributi investimento",
    "Wpłaty inwestycyjne",
    "Contribuições para Investimentos",
    "Взносы в инвестиции",
    "Yatırım Katkıları",
    "Інвестиційні внески",
    "Đóng góp đầu tư",
    "投资投入",
    "投資投入金額"
  ].freeze

  def up
    say_with_time "Stamping system_key on Investment Contributions categories" do
      backfill!
    end
  end

  def down
    # Clearing the keys would make the categories unreachable again, and the
    # merged duplicates cannot be un-merged. AddSystemKeyToCategories drops the
    # column outright if this really has to be reversed.
  end

  private
    def backfill!
      quoted_names = LEGACY_NAMES.map { |name| connection.quote(name) }.join(", ")

      rows = connection.select_all(<<~SQL.squish)
        SELECT c.id, c.family_id
        FROM categories c
        WHERE c.name IN (#{quoted_names})
          AND NOT EXISTS (
            SELECT 1 FROM categories existing
            WHERE existing.family_id = c.family_id
              AND existing.system_key = #{connection.quote(SYSTEM_KEY_INVESTMENT_CONTRIBUTIONS)}
          )
        ORDER BY c.family_id, c.created_at, c.id
      SQL

      stamped = 0

      # Oldest row per family wins, the same keeper the previous read-time
      # de-duplication picked (and BackfillInvestmentContributionCategories).
      rows.to_a.group_by { |row| row["family_id"] }.each_value do |family_rows|
        keeper_id, *duplicate_ids = family_rows.map { |row| row["id"] }

        duplicate_ids.each { |duplicate_id| merge_into!(keeper_id: keeper_id, duplicate_id: duplicate_id) }

        connection.execute(<<~SQL.squish)
          UPDATE categories
          SET system_key = #{connection.quote(SYSTEM_KEY_INVESTMENT_CONTRIBUTIONS)},
              updated_at = NOW()
          WHERE id = #{connection.quote(keeper_id)}
        SQL

        stamped += 1
      end

      stamped
    end

    # A frozen, deliberately simplified mirror of Category::Merger, kept as raw
    # SQL for the same reason this migration inlines LEGACY_NAMES: it must not
    # change behaviour when app code does. Like the Merger it moves children and
    # transactions onto the keeper and SUMS the two allocations where both rows
    # exist in the same budget, so merging never silently drops what a user
    # planned to spend.
    #
    # One duplicate at a time. budget_categories is unique on
    # (budget_id, category_id), so repointing several duplicates in one statement
    # would collide whenever two of them share a budget the keeper is absent from.
    def merge_into!(keeper_id:, duplicate_id:)
      keeper = connection.quote(keeper_id)
      duplicate = connection.quote(duplicate_id)

      connection.execute("UPDATE categories SET parent_id = #{keeper} WHERE parent_id = #{duplicate}")
      connection.execute("UPDATE transactions SET category_id = #{keeper} WHERE category_id = #{duplicate}")

      # Everything else that points at a category. recurring_transactions has a
      # foreign key with ON DELETE SET NULL, so deleting the duplicate would
      # silently clear its bills' category; the rest reference it with no foreign
      # key at all (rules keep the id as text), so they would just dangle.
      # MergeDuplicateTagAndCategoryNames repoints the same set, minus
      # recurring_transactions.
      connection.execute("UPDATE recurring_transactions SET category_id = #{keeper} WHERE category_id = #{duplicate}")
      connection.execute("UPDATE import_mappings SET mappable_id = #{keeper} WHERE mappable_type = 'Category' AND mappable_id = #{duplicate}")
      connection.execute("UPDATE import_source_mappings SET target_id = #{keeper} WHERE target_type = 'Category' AND target_id = #{duplicate}")
      connection.execute("UPDATE rule_actions SET value = #{keeper} WHERE action_type = 'set_transaction_category' AND value = #{duplicate}")
      connection.execute("UPDATE rule_conditions SET value = #{keeper} WHERE condition_type = 'transaction_category' AND value = #{duplicate}")

      # Budgets that hold both rows: fold the duplicate's allocation into the
      # keeper's, then drop the duplicate's row. Rollover is a standing choice
      # about the envelope, so it survives if EITHER row had it on; the carried
      # amount itself is derived and is recomputed by Budget::RolloverCalculator
      # the next time the budget loads.
      connection.execute(<<~SQL.squish)
        UPDATE budget_categories AS kept
        SET budgeted_spending = kept.budgeted_spending + dup.budgeted_spending,
            rollover_enabled = kept.rollover_enabled OR dup.rollover_enabled,
            updated_at = NOW()
        FROM budget_categories AS dup
        WHERE kept.category_id = #{keeper}
          AND dup.category_id = #{duplicate}
          AND kept.budget_id = dup.budget_id
      SQL
      connection.execute(<<~SQL.squish)
        DELETE FROM budget_categories
        WHERE category_id = #{duplicate}
          AND budget_id IN (SELECT budget_id FROM budget_categories WHERE category_id = #{keeper})
      SQL

      # Budgets that only held the duplicate: hand the row over.
      connection.execute("UPDATE budget_categories SET category_id = #{keeper} WHERE category_id = #{duplicate}")
      connection.execute("DELETE FROM categories WHERE id = #{duplicate}")
    end
end
