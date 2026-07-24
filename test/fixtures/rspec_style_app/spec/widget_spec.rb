# frozen_string_literal: true

RSpec.describe Widget do
  it "has a nil name by default" do
    expect(Widget.new.name).to be_nil
  end
end
