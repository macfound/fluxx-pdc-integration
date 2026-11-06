require 'net/http'
require 'uri'
require 'json'

# Validate that grantee has consented to sending data for this grant to the PDC.
grantee_consent = model.dyn_invoke_for(:"PDC Safe Consent Form Lookup")
if grantee_consent.blank?
	raise "Cannot send proposal to PDC: No consent form found for this grant."
elsif grantee_consent.last.consent_type.blank?
	raise "Cannot send proposal to PDC: Grantee has not indicated consent for this grant."
elsif grantee_consent.last.consent_type.match(".*[Dd]ecline.*")
	raise "Cannot send proposal to PDC: Grantee has declined consent for this grant."
end

# Check if this grant has already been sent to PDC
has_proposal_id = model.respond_to?(:pdc_proposal_id) && model.pdc_proposal_id.present?

# Get the PDC application form through the relationship model
pdc_app_form = model.dyn_invoke_for(:"PDC Get Integration Mapping")
raise "Cannot send proposal to PDC: No active PDC Integration Map has this grant's theme (#{model.model_theme&.name}): choose it in a map's Grant Request Themes." if pdc_app_form.nil?

# Get application form ID from the related record
application_form_id = nil
if pdc_app_form.respond_to?(:application) && pdc_app_form.application.present?
	# Parse the Id from a string like "Application #8 (Opp: 7, v.1)"
	application_form_id = pdc_app_form.application.gsub(/.*#(\d+).*/, '\1').to_i
else
	raise "PDC application form has no application ID set."
end

# Get opportunity ID from the related record
opportunity_id = nil
if pdc_app_form.respond_to?(:opportunity) && pdc_app_form.opportunity.present?
	# Lookup the Opprortunity ID from the ModelAttributeValue which matches this opporunity
	opporunityAttribute = ModelAttribute.where(
		model_type: 'MacModelTypeDynPdcApplicationForm1',
		name: 'opportunity'
	).first

	opportunityValue = ModelAttributeValue.where(
		model_attribute_id: opporunityAttribute.id,
		description: pdc_app_form.opportunity
	).first.tap do |choice|
		if choice
			opportunity_id = choice.value
		else
			raise "No matching ModelAttributeChoice found for PDC opportunity."
		end
	end
else
	raise "PDC application form has no opportunity ID set."
end

# Get base URL and auth token
base_url = pdc_app_form.dyn_invoke_for(:"Get PDC Base URL")
auth_token = pdc_app_form.dyn_invoke_for(:"Get Auth Token from PDC")

proposal_data = nil

if has_proposal_id
 	# Try to get existing proposal
 	begin
		proposal_data = model.dyn_invoke_for(:"PDC Get Proposal by ID from PDC")
 	rescue => e
		if e.message.include?("not found")
 			# Proposal ID is stale - we need to create a new one
 			has_proposal_id = false
 			model.update_attributes(pdc_proposal_id: nil) if model.respond_to?(:pdc_proposal_id=)
		else
 			raise "Error checking existing proposal: #{e.message}"
		end
 	end
end

if !has_proposal_id
 	# Create new proposal
 	proposal_body = {
		opportunityId: opportunity_id.to_i,
		externalId: model.id.to_s
 	}

 	endpoint = "#{base_url}/proposals"
 	uri = URI.parse(endpoint)

 	request = Net::HTTP::Post.new(uri)
 	request['Authorization'] = "Bearer #{auth_token}"
 	request['Accept'] = 'application/json'
 	request['Content-Type'] = 'application/json'
 	request.body = proposal_body.to_json

 	begin
		response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
		http.request(request)
		end

		case response.code
		when "201"
		proposal_data = JSON.parse(response.body)

		# Store the proposal ID
		if model.respond_to?(:pdc_proposal_id=)
 			model.update_attributes(pdc_proposal_id: proposal_data['id'])
		end

		action_taken = "created_new"

		when "401"
		raise "Unauthorized: Invalid or expired auth token"
		when "409"
		error_data = JSON.parse(response.body) rescue {}
		raise "Conflict creating proposal: #{error_data['message'] || response.body}"
		when "422"
		error_data = JSON.parse(response.body) rescue {}
		raise "Invalid proposal data: #{error_data['message'] || response.body}"
		else
		error_data = JSON.parse(response.body) rescue {}
		error_message = error_data['message'] || response.body
		raise "Failed to create proposal (#{response.code}): #{error_message}"
		end

 	rescue Net::OpenTimeout, Net::ReadTimeout
		raise "Timeout connecting to PDC API"
 	rescue SocketError, Errno::ECONNREFUSED
		raise "Cannot connect to PDC API at #{uri.hostname}"
 	rescue JSON::ParserError => e
		raise "Invalid JSON response: #{e.message}"
 	end
end

# Create field values from mappings
field_values = []
app_form_fields = {}
position = 0

begin
	# Get the application form structure once to build field ID mapping
	app_form_data = nil
	endpoint = "#{base_url}/applicationForms/#{application_form_id}"
	uri = URI.parse(endpoint)

	request = Net::HTTP::Get.new(uri)
	request['Authorization'] = "Bearer #{auth_token}"
	request['Accept'] = 'application/json'

	response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
		http.request(request)
	end

	if response.code == "200"
		app_form_data = JSON.parse(response.body)
	else
		raise "Failed to get application form structure (#{response.code})"
	end

	# Build mapping of PDC field codes to application form field IDs
	if app_form_data && app_form_data['fields']
		app_form_data['fields'].each do |field|
			if field['baseFieldShortCode'] && field['id']
				app_form_fields[field['baseFieldShortCode']] = field['id']
			end
		end
	end

rescue Net::OpenTimeout, Net::ReadTimeout
	raise "Timeout connecting to PDC API"
rescue SocketError, Errno::ECONNREFUSED
	raise "Cannot connect to PDC API at #{uri.hostname}"
rescue JSON::ParserError => e
	raise "Invalid JSON response: #{e.message}"
end
# Get all field mappings for this application form
field_mappings = pdc_app_form.reverse_pdc_mapping_field_MacModelTypeDynPdcMappedField1

field_mappings.each do |mapping|
	# logger << "Processing mapping ID #{mapping.id}"
	# Get the PDC field code
	pdc_field_code = mapping.respond_to?(:pdc_field) ? mapping.pdc_field : nil
	next if pdc_field_code.blank?
	pdc_field_code = pdc_field_code.strip.downcase.gsub(/[\s\-]+/, '_')

	# Get the Fluxx field code
	fluxx_field_code = mapping.respond_to?(:fluxx_field) ? mapping.fluxx_field : nil
	next if fluxx_field_code.blank?

	# logger << "  PDC Field Code: #{pdc_field_code}, Fluxx Field Code: #{fluxx_field_code}"
	# logger << "  Application Form Fields Mapping: #{app_form_fields.inspect}"

	# Get the application form field ID
	app_form_field_id = app_form_fields[pdc_field_code]
	next if app_form_field_id.nil?

	# What this mapping sends for this grant: the Fluxx field, or its related
	# field when it's a record; a record still left sends its Fluxx id (see
	# Value For Grant on PDC Mapped Field). An empty value, or a field that
	# can't be read, is left out: the PDC takes only string values, and one
	# field never stops the proposal.
	mapping.instance_variable_set(:@pdc_grant, model)
	field_value_str = (mapping.dyn_invoke_for(:"Value For Grant") rescue nil)
	next if field_value_str.nil?

	field_values << {
		applicationFormFieldId: app_form_field_id,
		position: position,
		value: field_value_str,
		goodAsOf: Time.current.iso8601
	}
	# logger << "  Final field value to send: #{field_value_str.inspect}"
	position += 1
end

version_body = {
	proposalId: proposal_data['id'].to_i,
	sourceId: 19,
	applicationFormId: application_form_id.to_i,
	fieldValues: field_values
}


endpoint = "#{base_url}/proposalVersions"
uri = URI.parse(endpoint)

request = Net::HTTP::Post.new(uri)
request['Authorization'] = "Bearer #{auth_token}"
request['Accept'] = 'application/json'
request['Content-Type'] = 'application/json'
request.body = version_body.to_json

begin
  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
    http.request(request)
  end

  case response.code
  when "201"
    # Success
    version_data = JSON.parse(response.body)

	# Store the proposal proposal ID
	model.update_attributes(pdc_proposal_id: version_data['proposalId'])

    # {
    #   proposal_version: version_data,
    #   proposal_id: proposal_id,
    #   field_count: field_values.length,
    #   message: "Created version #{version_data['version']} with #{field_values.length} fields"
    # }

  when "401"
    raise "Unauthorized: Invalid or expired auth token"
  when "422"
    error_data = JSON.parse(response.body) rescue {}
    error_message = error_data['message'] || response.body
    raise "Invalid entities referenced: #{error_message}"
  else
    error_data = JSON.parse(response.body) rescue {}
    error_message = error_data['message'] || response.body
    raise "Failed to create proposal version (#{response.code}): #{error_message}"
  end

rescue Net::OpenTimeout, Net::ReadTimeout
  raise "Timeout connecting to PDC API"
rescue SocketError, Errno::ECONNREFUSED
  raise "Cannot connect to PDC API at #{uri.hostname}"
rescue JSON::ParserError => e
  raise "Invalid JSON response: #{e.message}"
end
