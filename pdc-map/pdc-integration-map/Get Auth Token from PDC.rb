# Get Auth Token from PDC
# Returns access token string on success, raises error on failure

# Attempt to grab the Access Token from the current record
token_data = model.respond_to?(:authentication_token) && model.authentication_token.present? ? JSON.parse(model.authentication_token) : nil
if token_data && token_data["access_token"] &&
  token_data["expires_at"] &&
  Time.now.to_i < token_data["expires_at"]

  # Token is still valid
  token_data["access_token"]
else
  # Determine environment
  base_url = model.dyn_invoke_for(:"Get PDC Base URL")
  client_id = model.dyn_invoke_for(:"Get PDC Client ID")
  client_secret = model.dyn_invoke_for(:"Get PDC Client Secret")
  auth_url = "https://auth.philanthropydatacommons.org/realms/pdc/protocol/openid-connect/token"

  # Make token request
  uri = URI.parse(auth_url)
  request = Net::HTTP::Post.new(uri)

  request.body = URI.encode_www_form({
    grant_type: "client_credentials",
    client_id: client_id,
    client_secret: client_secret
  })
  request['Content-Type'] = 'application/x-www-form-urlencoded'

  begin
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      http.request(request)
    end

    case response.code
    when "200"
      token_data = JSON.parse(response.body)
      token_data["expires_at"] = 2.minutes.ago.to_i + token_data["expires_in"].to_i
      # Store the token data back on the model for future use
      model.authentication_token = token_data.to_json
      model.save(:validate => false)
      token_data["access_token"]
    when "400"
      error_data = JSON.parse(response.body) rescue {}
      raise "Bad request: #{error_data['error_description'] || response.body}"
    when "401"
      raise "Authentication failed: Invalid client credentials"
    when "404"
      raise "Auth endpoint not found: #{auth_url}"
    else
      raise "Unexpected response (#{response.code}): #{response.body}"
    end

  rescue Net::OpenTimeout, Net::ReadTimeout
    raise "Timeout connecting to PDC auth server"
  rescue SocketError, Errno::ECONNREFUSED
    raise "Cannot connect to PDC auth server at #{uri.hostname}"
  rescue JSON::ParserError => e
    raise "Invalid JSON response from auth server: #{e.message}"
  end
end
