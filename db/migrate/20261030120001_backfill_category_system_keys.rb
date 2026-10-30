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
# Re-runnable: only rows with a NULL system_key are considered, and a family
# that already has a stamped row is skipped.
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
          AND c.system_key IS NULL
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

        collapse_duplicates!(keeper_id: keeper_id, duplicate_ids: duplicate_ids) if duplicate_ids.any?

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

    # Mirrors what Family#investment_contributions_category did on read, so no
    # family loses data when that runtime de-duplication goes away.
    #
    # Budget rows are deleted where the keeper already holds one for the same
    # budget and repointed otherwise: budget_categories is unique on
    # (budget_id, category_id), so a blanket repoint would violate that index
    # for any budget containing both rows.
    def collapse_duplicates!(keeper_id:, duplicate_ids:)
      id_list = duplicate_ids.map { |id| connection.quote(id) }.join(", ")
      quoted_keeper = connection.quote(keeper_id)

      connection.execute("UPDATE categories SET parent_id = #{quoted_keeper} WHERE parent_id IN (#{id_list})")
      connection.execute("UPDATE transactions SET category_id = #{quoted_keeper} WHERE category_id IN (#{id_list})")
      connection.execute(<<~SQL.squish)
        DELETE FROM budget_categories
        WHERE category_id IN (#{id_list})
          AND budget_id IN (
            SELECT budget_id FROM budget_categories WHERE category_id = #{quoted_keeper}
          )
      SQL
      connection.execute("UPDATE budget_categories SET category_id = #{quoted_keeper} WHERE category_id IN (#{id_list})")
      connection.execute("DELETE FROM categories WHERE id IN (#{id_list})")
    end
end
