# PDC_Results
#
# Called from the deploy model's form (Liquid: model.PDC_Results). Reads the
# results fields, newest run first, and the headers of the two configuration
# snapshots (never their contents).

require 'json'

read = lambda do |field|
  raw = model.respond_to?(field) ? model.public_send(field).to_s : ''
  next nil if raw.strip.empty?
  begin
    JSON.parse(raw)
  rescue JSON::ParserError
    { 'title' => field, 'error' => 'These results could not be read.' }
  end
end

sections = %w[install_results uninstall_results restore_results validate_results installer_results credentials_results]
           .map { |f| read.call(f) }.compact.sort_by { |s| s['ran_at'].to_s }.reverse
snapshots = {}
{ 'previous' => 'previous_configuration', 'current' => 'current_configuration' }.each do |k, f|
  snap = read.call(f)
  snapshots[k] = snap['meta'] if snap.is_a?(Hash) && snap['meta']
end

{ 'sections' => sections, 'snapshots' => snapshots }
