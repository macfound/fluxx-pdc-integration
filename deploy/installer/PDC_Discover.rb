# PDC_Discover
#
# Read-only inventory of every PDC record on this instance, as defined by
# deploy/pdc-scope.json at this deploy model's repo_url / repo_ref. Code
# bodies appear as sha256 only. Returns pretty JSON.
#
# Underscored name so it can be rendered from Liquid: {{ model.PDC_Discover }}

require 'json'
require 'time'

lib = model.dyn_invoke_for(:"PDC Installer Lib")
begin
  scope = lib[:fetch_repo_json].call(model, 'deploy/pdc-scope.json')
  JSON.pretty_generate(
    'generated_at' => Time.now.utc.iso8601,
    'repo_url' => lib[:repo_settings].call(model)['repo_url'],
    'ref' => lib[:repo_ref].call(model),
    'deploy_model' => model.class.name,
    'live' => lib[:collect].call(scope, false)
  )
rescue => e
  JSON.pretty_generate('error' => "#{e.class}: #{e.message}")
end
