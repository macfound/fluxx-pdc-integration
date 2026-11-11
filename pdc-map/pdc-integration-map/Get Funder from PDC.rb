# Get Funder from PDC
# Returns funder object if found in PDC
# Priority: funder_organization.pdc_funder_short_code > model.funder_short_code
# Raises error if no short code provided or on API failures

require 'net/http'
require 'uri'
require 'json'

# Determine which funder short code to use
funder_short_code = nil

if model.respond_to?(:funder_short_code) && model.funder_short_code.present?
    funder_short_code = model.funder_short_code
else
  raise "Funder short code is required to create an opportunity"
end

# Get base URL and auth token
base_url = model.dyn_invoke_for(:"Get PDC Base URL")
auth_token = model.dyn_invoke_for(:"Get Auth Token from PDC")

# Construct the endpoint URL
endpoint = "#{base_url}/funders/#{funder_short_code}"
uri = URI.parse(endpoint)

# Create the request
request = Net::HTTP::Get.new(uri)
request['Authorization'] = "Bearer #{auth_token}"
request['Accept'] = 'application/json'

begin
  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
    http.request(request)
  end

  case response.code
  when "200"
    # Funder exists in PDC
    JSON.parse(response.body)
  when "404"
    # Funder doesn't exist in PDC
    # This helps determine if they can create it
    raise "Funder with short code '#{funder_short_code}' not found in PDC"
  when "401"
    raise "Unauthorized: Invalid or expired auth token"
  else
    error_data = JSON.parse(response.body) rescue {}
    error_message = error_data['message'] || response.body
    raise "PDC API error (#{response.code}): #{error_message}"
  end

rescue Net::OpenTimeout, Net::ReadTimeout
  raise "Timeout connecting to PDC API"
rescue SocketError, Errno::ECONNREFUSED
  raise "Cannot connect to PDC API at #{uri.hostname}"
rescue JSON::ParserError => e
  raise "Invalid JSON response: #{e.message}"
end
