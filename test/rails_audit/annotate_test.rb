# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require "test_helper"

class AnnotateTest < Minitest::Test
  HEADERS = [
    "Top 5 issues to fix first",
    "Systemic patterns",
    "Refactoring suggestions (thoughtbot style)",
    "Impact ranking critique"
  ].freeze

  def test_success_writes_unverified_annotations_and_surfaces_usage
    with_paths do |findings_path, output_path|
      fake = FakeClaude.new(success_envelope)
      stdout, stderr = StringIO.new, StringIO.new

      status = RailsAudit::Annotate.run(
        findings_path: findings_path, output_path: output_path, runner: fake,
        stdout: stdout, stderr: stderr
      )

      assert_equal 0, status
      assert_equal 1, fake.calls.size
      assert_equal ["claude", "-p", "--output-format", "json"], fake.calls.first.fetch(:argv).first(4)
      prompt = fake.calls.first.fetch(:argv).last
      HEADERS.each { |header| assert_includes prompt, "## #{header}" }
      assert_includes prompt, "Total findings: 1"

      annotations = File.read(output_path)
      assert_includes annotations, "UNVERIFIED second opinion"
      assert_includes annotations, "not ground truth"
      HEADERS.each { |header| assert_includes annotations, "## #{header}" }
      assert_includes stdout.string, "total_cost_usd=0.42"
      assert_includes stdout.string, '"input_tokens":12'
      assert_empty stderr.string
    end
  end

  def test_timeout_then_retry_success
    with_paths do |findings_path, output_path|
      fake = FakeClaude.new(timeout_result, success_envelope)

      status = RailsAudit::Annotate.run(
        findings_path: findings_path, output_path: output_path, runner: fake,
        stdout: StringIO.new, stderr: StringIO.new
      )

      assert_equal 0, status
      assert_equal 2, fake.calls.size
      assert_path_exists output_path
    end
  end

  def test_persistent_failure_fails_loud_without_writing_a_file
    with_paths do |findings_path, output_path|
      failure = result(stdout: "", stderr: "claude exploded", exit_status: 1)
      fake = FakeClaude.new(failure, failure)
      stderr = StringIO.new

      status = RailsAudit::Annotate.run(
        findings_path: findings_path, output_path: output_path, runner: fake,
        stdout: StringIO.new, stderr: stderr
      )

      assert_equal 1, status
      assert_equal 2, fake.calls.size
      assert_includes stderr.string, "claude exploded"
      refute_path_exists output_path
    end
  end

  def test_malformed_json_retries_then_fails_without_writing_a_file
    with_paths do |findings_path, output_path|
      malformed = result(stdout: "not json", stderr: "", exit_status: 0)
      fake = FakeClaude.new(malformed, malformed)
      stderr = StringIO.new

      status = RailsAudit::Annotate.run(
        findings_path: findings_path, output_path: output_path, runner: fake,
        stdout: StringIO.new, stderr: stderr
      )

      assert_equal 1, status
      assert_equal 2, fake.calls.size
      assert_includes stderr.string, "no stderr"
      refute_path_exists output_path
    end
  end

  private

  FakeClaude = Struct.new(:responses, :calls) do
    def initialize(*responses)
      super(responses, [])
    end

    def call(argv, timeout:)
      calls << { argv: argv, timeout: timeout }
      responses.shift
    end
  end

  def success_envelope
    body = HEADERS.map { |header| "## #{header}\nAdvice." }.join("\n\n")
    result(stdout: JSON.generate(result: body, total_cost_usd: 0.42, usage: { input_tokens: 12 }),
           stderr: "", exit_status: 0)
  end

  def timeout_result
    result(stdout: "", stderr: "", exit_status: nil, timed_out: true)
  end

  def result(stdout:, stderr:, exit_status:, timed_out: false)
    RailsAudit::Annotate::InvocationResult.new(
      stdout: stdout, stderr: stderr, exit_status: exit_status, timed_out: timed_out
    )
  end

  def with_paths
    Dir.mktmpdir do |dir|
      findings_path = File.join(dir, "findings.json")
      output_path = File.join(dir, "ANNOTATIONS.md")
      File.write(findings_path, JSON.generate(document))
      yield findings_path, output_path
    end
  end

  def document
    {
      target: "target/app",
      tools: [{ name: "rubocop", version: "1.88.2", raw_count: 1, exit_code: 1 }],
      findings: [{
        id: "id", native_fingerprint: nil, tool: "rubocop", rule: "Style/Foo",
        category: "style", impact: "info", confidence: "medium", message: "message",
        location: { file: "a.rb", start_line: 1, end_line: 1, column: nil, lines: nil }, context: nil
      }]
    }
  end
end
