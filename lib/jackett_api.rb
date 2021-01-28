require 'net/http'
require 'json'

module JackettAPI
  extend self

  BASE_URL = ENV['JACKETT_BASE_URL'] ? ENV['JACKETT_BASE_URL'] : "http://localhost:9117"
  API_URL = "#{BASE_URL}/api/v2.0"



  def get(query)
    uri = URI.parse("#{API_URL}/indexers/all/results")

    params = {
      apikey: "mph009qgje8zup18p644ywur8365ptlm",
      Query: query,
      Tracker: "iptorrents"
    }
    uri.query = URI.encode_www_form(params)

    req = Net::HTTP::Get.new(uri.to_s)
    res = Net::HTTP.start(uri.host, uri.port) { |http|
      http.request(req)
    }

    JSON.parse(res.body)
  end

  def blackhole(path)
  end
end
