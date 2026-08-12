class ResilienceExamples
  def interrupt_work
    Timeout.timeout(1) { work }
  end

  def fetch_with_defaults
    Net::HTTP.get(uri)
  end

  def build_http_client
    Net::HTTP.new(host)
  end

  def build_faraday_client
    Faraday.new(url)
  end
end

class RemoteClient
  include HTTParty
end

Rack::Timeout.service_timeout = false
