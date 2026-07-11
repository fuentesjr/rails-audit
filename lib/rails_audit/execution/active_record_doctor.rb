# frozen_string_literal: true

require "stringio"

require File.expand_path("config/environment", Dir.pwd)
Rails.application.eager_load!
require "active_record_doctor"

config = ActiveRecordDoctor.load_config_with_defaults(nil)
logger = ActiveRecordDoctor::Logger::Dummy.new
had_findings = false
had_error = false

puts "RAILS_AUDIT_ACTIVE_RECORD_DOCTOR_BEGIN 1"
ActiveRecordDoctor.detectors.each_key do |detector|
  output = StringIO.new
  success = ActiveRecordDoctor::Runner.new(config: config, logger: logger, io: output).run_one(detector)
  messages = output.string.lines(chomp: true)
  status = if success
             "clean"
           elsif messages.empty?
             had_error = true
             "error"
           else
             had_findings = true
             "findings"
           end

  puts "RAILS_AUDIT_DETECTOR_BEGIN #{detector}"
  messages.each { |message| puts message }
  puts "RAILS_AUDIT_DETECTOR_END #{detector} #{status}"
end
puts "RAILS_AUDIT_ACTIVE_RECORD_DOCTOR_END"

exit(2) if had_error
exit(1) if had_findings
