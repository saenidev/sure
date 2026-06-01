module AppCache
  VERSION = "v1"
  DEFAULT_EXPIRES_IN = 15.minutes
  DEFAULT_RACE_CONDITION_TTL = 10.seconds
  DEFAULT_VERSIONS = %i[family accounts entries categories account_shares].freeze

  module_function

  def fetch_user_data(family:, user:, namespace:, parts: [], versions: DEFAULT_VERSIONS, expires_in: DEFAULT_EXPIRES_IN, race_condition_ttl: DEFAULT_RACE_CONDITION_TTL, &block)
    Rails.cache.fetch(
      user_data_key(family: family, user: user, namespace: namespace, parts: parts, versions: versions),
      expires_in: expires_in,
      race_condition_ttl: race_condition_ttl,
      &block
    )
  end

  def user_data_key(family:, user:, namespace:, parts: [], versions: DEFAULT_VERSIONS)
    [
      "app-cache",
      VERSION,
      "user-data",
      namespace,
      "family", family.id,
      "user", user&.id || "anonymous",
      "locale", I18n.locale,
      "versions", versions.index_with { |version| version_value(version, family: family, user: user) },
      "parts", normalize_cache_part(parts)
    ]
  end

  def relation_version(relation, timestamp_column: :updated_at)
    table_name = relation.klass.quoted_table_name
    column_name = ActiveRecord::Base.connection.quote_column_name(timestamp_column)
    count, max_at = relation
      .unscope(:select, :order)
      .pick(Arel.sql("COUNT(*)"), Arel.sql("MAX(#{table_name}.#{column_name})"))

    "#{count.to_i}-#{max_at&.to_i || 0}"
  end

  def version_value(version, family:, user:)
    return uncached_version_value(version, family: family, user: user) unless request_version_cache_enabled?

    cache_key = [ family.id, user&.id || "anonymous", version ]
    request_version_cache.fetch(cache_key) do
      request_version_cache[cache_key] = uncached_version_value(version, family: family, user: user)
    end
  end

  def uncached_version_value(version, family:, user:)
    case version
    when :family
      [
        relation_version(Family.where(id: family.id)),
        family.currency,
        family.latest_sync_completed_at&.to_i || 0
      ]
    when :accounts
      relation_version(family.accounts)
    when :entries
      family.entries_cache_version
    when :categories
      relation_version(family.categories)
    when :account_shares
      user ? relation_version(AccountShare.where(user_id: user.id)) : "anonymous"
    when :budgets
      [ relation_version(family.budgets), relation_version(family.budget_categories) ]
    when :holdings
      relation_version(family.holdings)
    when :recurring_transactions
      relation_version(family.recurring_transactions)
    else
      raise ArgumentError, "Unknown app cache version: #{version.inspect}"
    end
  end

  def request_version_cache
    Current.app_cache_versions ||= {}
  end

  def request_version_cache_enabled?
    Current.session.present?
  end

  def normalize_cache_part(value)
    case value
    when Hash
      value.to_h.stringify_keys.sort.map { |key, child| [ key, normalize_cache_part(child) ] }
    when Array
      value.map { |child| normalize_cache_part(child) }
    when Date, Time, ActiveSupport::TimeWithZone
      value.iso8601
    else
      value
    end
  end
end
