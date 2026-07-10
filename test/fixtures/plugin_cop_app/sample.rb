# frozen_string_literal: true

class Sample
  def now
    now = Time.now
    now
  end

  def replace(str)
    str.gsub("a", "b")
  end
end
