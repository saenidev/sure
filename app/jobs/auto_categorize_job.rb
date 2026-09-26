class AutoCategorizeJob < ApplicationJob
  queue_as :medium_priority

  PROVIDER_ATTEMPTS = 3

  # LLM calls fail transiently (upstream 5xx, truncated JSON). Retry those, and
  # only record the rule run failure once the retries are spent — failing it on
  # an early attempt would mark the run failed even if a retry then succeeds.
  retry_on Family::AutoCategorizer::ProviderError, wait: 5.minutes, attempts: PROVIDER_ATTEMPTS do |job, error|
    options = job.arguments.last.is_a?(Hash) ? job.arguments.last : {}
    rule_run = RuleRun.find_by(id: options[:rule_run_id]) if options[:rule_run_id].present?
    rule_run&.fail_job!(error: error, source: job.class.name, transaction_ids: Array(options[:transaction_ids]))
  end

  def perform(family, transaction_ids: [], rule_run_id: nil)
    rule_run = RuleRun.find_by(id: rule_run_id) if rule_run_id.present?
    modified_count = family.auto_categorize_transactions(transaction_ids)

    # If this job was part of a rule run, report back the modified count
    rule_run&.complete_job!(modified_count: modified_count)
  rescue Family::AutoCategorizer::ProviderError
    raise
  rescue => error
    rule_run&.fail_job!(error: error, source: self.class.name, transaction_ids: transaction_ids)

    raise
  end
end
