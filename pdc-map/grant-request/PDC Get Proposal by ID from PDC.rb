# Get Proposal by ID from PDC
# Returns proposal object if found, raises error if not found or on API failure
# Expects model to have pdc_proposal_id field

require 'net/http'
require 'uri'
require 'json'

# Check if we have a proposal ID to look up
if !model.respond_to?(:pdc_proposal_id) || model.pdc_proposal_id.blank?
  raise "No PDC proposal ID found. Cannot look up proposal."
end

proposal_id = model.pdc_proposal_id

pdc_integration_form = model.dyn_invoke_for(:"PDC Get Integration Mapping")
raise "No active PDC Integration Map has this grant's theme (#{model.model_theme&.name}): choose it in a map's Grant Request Themes." if pdc_integration_form.nil?

# Get base URL and auth token
base_url = pdc_integration_form.dyn_invoke_for(:"Get PDC Base URL")
auth_token = pdc_integration_form.dyn_invoke_for(:"Get Auth Token from PDC")

# Construct endpoint URL
endpoint = "#{base_url}/proposals/#{proposal_id}"
uri = URI.parse(endpoint)

# Create request
request = Net::HTTP::Get.new(uri)
request['Authorization'] = "Bearer #{auth_token}"
request['Accept'] = 'application/json'

begin
  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
    http.request(request)
  end
  
  case response.code
  when "200"
    # Success - return the proposal
    JSON.parse(response.body)
  when "401"
    raise "Unauthorized: Invalid or expired auth token"
  when "404"
    # Proposal doesn't exist - this helps determine if we need to create it
    raise "Proposal with ID #{proposal_id} not found in PDC"
  else
    error_data = JSON.parse(response.body) rescue {}
    error_message = error_data['message'] || response.body
    raise "Failed to get proposal (#{response.code}): #{error_message}"
  end
  
rescue Net::OpenTimeout, Net::ReadTimeout
  raise "Timeout connecting to PDC API"
rescue SocketError, Errno::ECONNREFUSED
  raise "Cannot connect to PDC API at #{uri.hostname}"
rescue JSON::ParserError => e
  raise "Invalid JSON response: #{e.message}"
end