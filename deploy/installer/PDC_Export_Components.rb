# PDC_Export_Components
#
# Extraction from a known-good instance. Same inventory as PDC_Discover, but
# every code body (methods, theme hooks, state hooks, event guards, owned
# stencil JSON, the shared GrantRequest slice) is included as normalized
# text. The result is one "PDCEXPORT1:..." line (deflated base64), because the
# console collapses whitespace in plain JSON. Save it to a file and run:
#
#   ruby deploy/tools/pdc_manifest.rb unpack <export.json>
#
# which writes the bodies into the repo and regenerates
# deploy/pdc-manifest.json. Secret methods are never exported.
#
# Underscored name so it can be rendered from Liquid:
# {{ model.PDC_Export_Components }}

require 'json'
require 'time'

lib = model.dyn_invoke_for(:"PDC Installer Lib")
begin
  scope = lib[:fetch_repo_json].call(model, 'deploy/pdc-scope.json')
  lib[:pack_export].call(
    'export_format' => 1,
    'exported_at' => Time.now.utc.iso8601,
    'repo_url' => lib[:repo_settings].call(model)['repo_url'],
    'ref' => lib[:repo_ref].call(model),
    'deploy_model' => model.class.name,
    'live' => lib[:collect].call(scope, true)
  )
rescue => e
  JSON.pretty_generate('error' => "#{e.class}: #{e.message}")
end
