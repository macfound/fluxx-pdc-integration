# Get Base Fields from PDC
# Returns an array of base field hashes, deduped by shortCode.
# Handles the paged /baseFields endpoint.

require 'net/http'
require 'uri'
require 'json'

base_url   = model.dyn_invoke_for(:"Get PDC Base URL")
auth_token = model.dyn_invoke_for(:"Get Auth Token from PDC")

requested_count = 1000
sensitivity     = '!["forbidden"]'  # matches the documented default
max_pages       = 50                # runaway guard

all_fields = []
seen_codes = {}
page       = 1
page_size  = nil

while page <= max_pages
  uri = URI.parse("#{base_url}/baseFields")
  uri.query = URI.encode_www_form(
    "_page"                      => page,
    "_count"                     => requested_count,
    "sensitivityClassifications" => sensitivity
  )

  request = Net::HTTP::Get.new(uri)
  request['Authorization'] = "Bearer #{auth_token}"
  request['Accept']        = 'application/json'

  body = nil

  begin
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      http.request(request)
    end

    case response.code
    when "200"
      body = JSON.parse(response.body)
    when "401"
      raise "Unauthorized: invalid or expired auth token"
    when "404"
      raise "Base fields endpoint not found at #{base_url}/baseFields"
    else
      err = JSON.parse(response.body) rescue {}
      raise "Failed to get base fields (#{response.code}) on page #{page}: #{err['message'] || response.body}"
    end
  rescue Net::OpenTimeout, Net::ReadTimeout
    raise "Timeout connecting to PDC API on page #{page}"
  rescue SocketError, Errno::ECONNREFUSED
    raise "Cannot connect to PDC API at #{uri.hostname}"
  rescue JSON::ParserError => e
    raise "Invalid JSON response on page #{page}: #{e.message}"
  end

  # The endpoint used to return a bare array. Accept either shape so this
  # keeps working if PDC changes it back.
  batch = if body.is_a?(Array)
    body
  elsif body.is_a?(Hash)
    body["entries"] || body["items"] || body["data"] || []
  else
    []
  end

  break if batch.empty?

  new_in_batch = 0
  batch.each do |field|
    code = field["shortCode"]
    next if code.nil? || code.to_s.strip.empty?
    next if seen_codes[code]

    seen_codes[code] = true
    all_fields << field
    new_in_batch += 1
  end

  # If the page returned nothing we had not already seen, the server is
  # repeating a page rather than advancing. Stop.
  break if new_in_batch.zero?

  # The server may cap _count below what we asked for. Learn the effective
  # page size from the first response, then treat any short page as the last.
  page_size ||= batch.size
  break if batch.size < page_size

  page += 1
end

all_fields
