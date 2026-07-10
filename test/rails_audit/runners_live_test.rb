# frozen_string_literal: true

require "tmpdir"
require "test_helper"

class RunnersLiveTest < Minitest::Test
  TARGET = File.expand_path("../fixtures/target_app", __dir__)

  def test_brakeman_runner_against_real_tool
    with_output_path("brakeman.json") do |output_path|
      result = RailsAudit::Runners.brakeman(target: TARGET, output_path: output_path)

      assert_equal 3, result.fetch(:exit_code)
      assert_operator result.fetch(:raw_count), :>, 0
      assert_operator result.fetch(:payload).fetch("warnings").size, :>, 0
    end
  end

  def test_rubocop_runner_against_real_tool
    with_output_path("rubocop.json") do |output_path|
      with_environment("XDG_CACHE_HOME" => File.join(File.dirname(output_path), "cache")) do
        result = RailsAudit::Runners.rubocop(target: TARGET, output_path: output_path)

        assert_equal 1, result.fetch(:exit_code)
        assert_operator result.fetch(:raw_count), :>, 0
        assert_operator result.fetch(:payload).fetch("summary").fetch("offense_count"), :>, 0
      end
    end
  end

  def test_reek_runner_against_real_tool
    with_output_path("reek.json") do |output_path|
      result = RailsAudit::Runners.reek(target: TARGET, output_path: output_path)

      assert_equal 2, result.fetch(:exit_code)
      assert_operator result.fetch(:raw_count), :>, 0
      assert_operator result.fetch(:payload).size, :>, 0
    end
  end

  private

  def with_output_path(filename)
    Dir.mktmpdir do |dir|
      yield File.join(dir, filename)
    end
  end

  def with_environment(values)
    original = values.to_h { |key, _value| [key, ENV.fetch(key, nil)] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    original.each { |key, value| ENV[key] = value }
  end
end
