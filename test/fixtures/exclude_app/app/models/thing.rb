# frozen_string_literal: true

# Ordinary application code with the same offense as db/schema.rb, used to
# prove the CLI-owned Exclude list doesn't over-exclude real app code.
class Thing
  def greeting(user)
    if user.name == nil
      "Unknown"
    else
      "Hello"
    end
  end
end
