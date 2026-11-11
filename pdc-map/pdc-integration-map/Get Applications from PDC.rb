# Get All Applications from PDC
# Returns array of all applications, handling pagination automatically
# Raises error on failure

# Get configuration
base_url = model.dyn_invoke_for(:"Get PDC Base URL")
auth_token = model.dyn_invoke_for(:"Get Auth Token from PDC")

applications = []
page = 1
per_page = 100  # Standard pagination size
total_count = nil

begin
  loop do
    # Build URL with pagination params
    uri = URI.parse("#{base_url}/applicationForms")
    params = { _page: page, _count: per_page }
    uri.query = URI.encode_www_form(params)
    
    # Make request
    request = Net::HTTP::Get.new(uri)
    request['Authorization'] = "Bearer #{auth_token}"
    request['Accept'] = 'application/json'
    
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      http.request(request)
    end
    
    case response.code
    when "200"
      data = JSON.parse(response.body)
      
      # Extract total from bundle structure
      total_count = data['total']
      
      # Add applications from this page
      batch = data['entries'] || []
      applications.concat(batch)
      
      # Check if we've fetched everything
      # Stop if no more entries or we've reached the total
      break if batch.empty?
      break if applications.length >= total_count
      
      page += 1
      
    when "401"
      raise "Authentication failed. Token may be expired."
    when "404"
      raise "Applications endpoint not found at #{uri}"
    else
      error_body = JSON.parse(response.body) rescue response.body
      raise "API error (#{response.code}): #{error_body}"
    end
  end
  
  # Return array of applications
  applications
  
rescue Net::OpenTimeout, Net::ReadTimeout
  raise "Timeout connecting to PDC API"
rescue SocketError, Errno::ECONNREFUSED
  raise "Cannot connect to PDC API at #{uri.hostname}"
rescue JSON::ParserError => e
  raise "Invalid JSON response: #{e.message}"
end