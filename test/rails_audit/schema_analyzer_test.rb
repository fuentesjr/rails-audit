# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"
require "test_helper"

class SchemaAnalyzerTest < Minitest::Test
  TARGET = File.expand_path("../fixtures/schema_app", __dir__)

  def test_reports_all_five_schema_rules_with_expected_locations_and_mappings
    Dir.mktmpdir do |dir|
      result = RailsAudit::SchemaAnalyzer.analyze(
        target: TARGET, output_path: File.join(dir, "schema.json")
      )
      findings = RailsAudit::Normalizer.schema(result.fetch(:payload), target_root: TARGET)

      assert_finding findings, "Schema/TableWithoutPrimaryKey", 8, "high", "rails"
      assert_finding findings, "Schema/ShortPrimaryKeyType", 12, "medium", "rails"
      assert_finding findings, "Schema/MismatchedForeignKeyType", 21, "high", "rails"
      assert_finding findings, "Schema/UnindexedForeignKey", 22, "medium", "performance"
      assert_finding findings, "Schema/ExtraneousIndex", 28, "low", "performance"
      assert_empty(findings.select { |finding| finding.discriminator.start_with?("users.") })
      assert_empty(findings.select do |finding|
        finding.discriminator.start_with?("attachments.")
      end)
      assert_empty(findings.select { |finding| finding.discriminator.start_with?("manual_keys.") })
    end
  end

  def test_distinguishes_explicit_and_inferred_foreign_key_confidence
    Dir.mktmpdir do |dir|
      payload = RailsAudit::SchemaAnalyzer.analyze(
        target: TARGET, output_path: File.join(dir, "schema.json")
      ).fetch(:payload)
      findings = RailsAudit::Normalizer.schema(payload, target_root: TARGET)
      account_index = findings.find do |finding|
        finding.rule == "Schema/UnindexedForeignKey" &&
          finding.discriminator == "orders.account_id"
      end
      owner_index = findings.find do |finding|
        finding.rule == "Schema/UnindexedForeignKey" &&
          finding.discriminator == "orders.owner_id"
      end
      inferred_mismatch = findings.find do |finding|
        finding.rule == "Schema/MismatchedForeignKeyType" &&
          finding.discriminator == "inferred_comments.user_id"
      end

      assert_equal "high", account_index.confidence
      assert_equal "medium", owner_index.confidence
      assert_equal "medium", inferred_mismatch.confidence
    end
  end

  def test_writes_deterministic_raw_json_and_returns_runner_result_shape
    Dir.mktmpdir do |dir|
      output_path = File.join(dir, "schema.json")
      result = RailsAudit::SchemaAnalyzer.analyze(target: TARGET, output_path: output_path)

      assert_equal %i[name version raw_count exit_code payload output_path], result.keys
      assert_equal "schema", result.fetch(:name)
      assert_equal RailsAudit::VERSION, result.fetch(:version)
      assert_equal 0, result.fetch(:exit_code)
      assert_equal result.fetch(:payload).size, result.fetch(:raw_count)
      assert_equal result.fetch(:payload), JSON.parse(File.read(output_path))
    end
  end

  def test_absent_schema_returns_an_empty_result
    Dir.mktmpdir do |target|
      output_path = File.join(target, "raw", "schema.json")
      result = RailsAudit::SchemaAnalyzer.analyze(target: target, output_path: output_path)

      assert_equal 0, result.fetch(:raw_count)
      assert_empty result.fetch(:payload)
      refute_path_exists output_path
    end
  end

  def test_unique_prefix_index_is_not_extraneous_but_non_unique_prefix_is
    schema = <<~SCHEMA
      ActiveRecord::Schema[7.0].define(version: 1) do
        create_table "users", force: :cascade do |t|
          t.string "email", null: false
          t.bigint "tenant_id"
          t.datetime "created_at"
          t.index ["email"], name: "idx_email_unique", unique: true
          t.index ["email", "tenant_id"], name: "idx_email_tenant"
          t.index ["tenant_id"], name: "idx_tenant"
          t.index ["tenant_id", "created_at"], name: "idx_tenant_created"
        end
      end
    SCHEMA

    findings = analyze_schema(schema)
    extraneous = findings.select { |finding| finding.rule == "Schema/ExtraneousIndex" }
                         .map(&:discriminator)

    # The unique single-column index (a prefix of idx_email_tenant) enforces a constraint the
    # composite index does not, so it must not be reported as redundant.
    refute_includes extraneous, "users.idx_email_unique"
    # The non-unique idx_tenant IS a genuine leading-prefix of idx_tenant_created — still flagged.
    assert_includes extraneous, "users.idx_tenant"
  end

  def test_function_default_columns_parse_without_crashing
    schema = <<~SCHEMA
      ActiveRecord::Schema[7.0].define(version: 1) do
        create_table "widgets", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
          t.uuid "owner_id", default: -> { "gen_random_uuid()" }
          t.datetime "created_at", default: -> { "CURRENT_TIMESTAMP" }
        end
      end
    SCHEMA

    findings = analyze_schema(schema)

    # The `default: -> { ... }` function defaults the schema dumper emits for Postgres must not
    # crash the parse; owner_id is still modeled, so its unindexed-FK finding proves the column
    # survived the lambda-valued option.
    assert_includes findings.map(&:rule), "Schema/UnindexedForeignKey"
  end

  def test_inferred_foreign_key_to_custom_primary_key_table_does_not_crash
    schema = <<~SCHEMA
      ActiveRecord::Schema[7.0].define(version: 1) do
        create_table "line_items", force: :cascade do |t|
          t.integer "product_id"
        end
        create_table "products", id: false, force: :cascade do |t|
          t.primary_key "sku", type: :string
        end
      end
    SCHEMA

    findings = analyze_schema(schema)

    # products has a non-`id` string primary key, so the inferred product_id→products comparison
    # has no comparable target type — it must skip cleanly, not crash on nil.
    assert_empty findings.select { |finding| finding.rule == "Schema/MismatchedForeignKeyType" }
  end

  def test_exact_duplicate_indexes_flag_all_but_one_kept_deterministically
    schema = <<~SCHEMA
      ActiveRecord::Schema[7.0].define(version: 1) do
        create_table "tags", force: :cascade do |t|
          t.string "slug"
          t.bigint "kind_id"
          t.index ["slug"], name: "idx_tags_slug_a"
          t.index ["slug"], name: "idx_tags_slug_b"
          t.index ["kind_id"], name: "idx_kind_plain"
          t.index ["kind_id"], name: "idx_kind_unique", unique: true
        end
      end
    SCHEMA

    extraneous = analyze_schema(schema)
                 .select { |finding| finding.rule == "Schema/ExtraneousIndex" }
                 .map(&:discriminator)

    # Of the two identical non-unique [slug] indexes, exactly one is reported redundant.
    assert_equal 1, extraneous.count { |d| d.start_with?("tags.idx_tags_slug") }
    # Of the [kind_id] duplicate pair the non-unique index is dropped, the unique one kept.
    assert_includes extraneous, "tags.idx_kind_plain"
    refute_includes extraneous, "tags.idx_kind_unique"
  end

  private

  def analyze_schema(schema)
    Dir.mktmpdir do |target|
      FileUtils.mkdir_p(File.join(target, "db"))
      File.write(File.join(target, "db", "schema.rb"), schema)
      payload = RailsAudit::SchemaAnalyzer.analyze(
        target: target, output_path: File.join(target, "schema.json")
      ).fetch(:payload)
      return RailsAudit::Normalizer.schema(payload, target_root: target)
    end
  end

  def assert_finding(findings, rule, line, impact, category)
    finding = findings.find { |candidate| candidate.rule == rule && candidate.location[:start_line] == line }

    refute_nil finding, "expected #{rule} on line #{line}"
    assert_equal impact, finding.impact
    assert_equal category, finding.category
    assert_equal "db/schema.rb", finding.location.fetch(:file)
  end
end
