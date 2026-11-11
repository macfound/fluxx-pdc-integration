# Get Application Form by ID from PDC
# Returns the complete application form with fields
# Expects model to have application_form_id field
# Raises error if not found or on API failure

require 'net/http'
require 'uri'
require 'json'

# Get the application form ID from the application dropdown
if !model.respond_to?(:application) || model.application.blank?
  raise "No application form ID found. Application field must be set."
end

# The model.application contains the stored value (could be ID or description)
# We need to ensure we have the actual ID
app_form_id = model.application

# If the value contains non-numeric characters, it might be storing the description
# In that case, we need to look up the actual ID from the ModelAttributeValue
if app_form_id.to_s !~ /^\d+$/
  # Find the application attribute
  application_attribute = ModelAttribute.find_by(
    model_type: model.class.name,
    name: "application"
  )
  
  if application_attribute
    # Find the attribute value by description
    attr_value = ModelAttributeValue.find_by(
      model_attribute_id: application_attribute.id,
      description: app_form_id
    )
    
    if attr_value && attr_value.value.present?
      app_form_id = attr_value.value
    else
      raise "Could not find application form ID for: #{app_form_id}"
    end
  else
    raise "Application attribute not found on model"
  end
end

# Get base URL and auth token
base_url = model.dyn_invoke_for(:"Get PDC Base URL")
auth_token = model.dyn_invoke_for(:"Get Auth Token from PDC")

# Construct endpoint URL
endpoint = "#{base_url}/applicationForms/#{app_form_id}"
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
    # Success - return the application form
    JSON.parse(response.body)
  when "401"
    raise "Unauthorized: Invalid or expired auth token"
  when "404"
    raise "Application form with ID #{app_form_id} not found in PDC"
  else
    error_data = JSON.parse(response.body) rescue {}
    error_message = error_data['message'] || response.body
    raise "Failed to get application form (#{response.code}): #{error_message}"
  end
  
rescue Net::OpenTimeout, Net::ReadTimeout
  raise "Timeout connecting to PDC API"
rescue SocketError, Errno::ECONNREFUSED
  raise "Cannot connect to PDC API at #{uri.hostname}"
rescue JSON::ParserError => e
  raise "Invalid JSON response: #{e.message}"
end