require "test_helper"
require "fileutils"
require "open3"

class DockerEntrypointTest < ActiveSupport::TestCase
  test "prepares database before server boot by default" do
    with_entrypoint_app do |app_dir, calls_path|
      _stdout, _stderr, status = Open3.capture3(
        { "ENTRYPOINT_CALLS_PATH" => calls_path.to_s },
        Rails.root.join("bin/docker-entrypoint").to_s,
        "./bin/rails",
        "server",
        chdir: app_dir.to_s
      )

      assert status.success?
      assert_equal [ "db:prepare", "server" ], calls_path.read.lines.map(&:strip)
    end
  end

  test "skips database preparation when boot prepare is disabled" do
    with_entrypoint_app do |app_dir, calls_path|
      _stdout, _stderr, status = Open3.capture3(
        { "RUN_DB_PREPARE_ON_BOOT" => "false", "ENTRYPOINT_CALLS_PATH" => calls_path.to_s },
        Rails.root.join("bin/docker-entrypoint").to_s,
        "./bin/rails",
        "server",
        chdir: app_dir.to_s
      )

      assert status.success?
      assert_equal [ "server" ], calls_path.read.lines.map(&:strip)
    end
  end

  private
    def with_entrypoint_app
      Dir.mktmpdir("sure-entrypoint-test") do |dir|
        app_dir = Pathname(dir)
        bin_dir = app_dir.join("bin")
        calls_path = app_dir.join("calls.log")
        FileUtils.mkdir_p(bin_dir)

        rails_stub = bin_dir.join("rails")
        rails_stub.write(<<~SH)
          #!/bin/sh
          echo "$*" >> "$ENTRYPOINT_CALLS_PATH"
          exit 0
        SH
        FileUtils.chmod("+x", rails_stub)

        yield app_dir, calls_path
      end
    end
end
