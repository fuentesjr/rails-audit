# frozen_string_literal: true

class ReportBuilder
  def greeting(user)
    if user.name == nil
      "Unknown"
    else
      "Hello #{user.name}, from #{user.name}"
    end
  end
end
