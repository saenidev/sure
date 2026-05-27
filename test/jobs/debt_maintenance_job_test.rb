require "test_helper"

class DebtMaintenanceJobTest < ActiveJob::TestCase
  test "runs maintenance for the provided date" do
    runner = mock
    runner.expects(:call).returns(
      Debt::MaintenanceRunner::Result.new(processed_count: 0, error_count: 0, errors: [])
    )

    Debt::MaintenanceRunner.expects(:new)
      .with(as_of: Date.new(2026, 1, 31))
      .returns(runner)

    DebtMaintenanceJob.perform_now(as_of: "2026-01-31")
  end

  test "schedule contains daily debt maintenance job" do
    schedule = YAML.load_file(Rails.root.join("config/schedule.yml"))

    assert_equal "DebtMaintenanceJob", schedule.dig("debt_maintenance", "class")
    assert_equal "scheduled", schedule.dig("debt_maintenance", "queue")
    assert_match(/\A\d+ \d+ \* \* \*\z/, schedule.dig("debt_maintenance", "cron"))
  end
end
