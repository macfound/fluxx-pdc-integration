# PDC Validate Install
#
# The Validate button. Compares this instance against deploy/pdc-manifest.json
# at the deploy model's repo_url / repo_ref, which previews what Install would
# change. Reports, per component:
#   MATCH             found, checksums and settings agree
#   DIFFERS           found, but a checksum or setting differs (detail lists which)
#   MISSING           nothing with that name/key exists
#   EXTRA             a live PDC record the manifest doesn't know about
#   SKIPPED_SECRET    secret method; existence checked, body never compared
#   NOT_CONFIGURED    secret method still holds its placeholder, or no PDC
#                     Environment is chosen for Get PDC Base URL
#   MARKER_NOT_FOUND  shared hook exists but has no ###PDC_CODE### block
#   MISSING_ROLE / ROLE_DIFFERS  event has no role / not the pdc_event_role chosen here
#   UNMARKED          PDC stencil element found by fingerprint, no PDC:ELEMENT marker yet
#                     (content matches the repo)
#   UNMARKED_DIFFERS  same, but the content differs from the repo copy
#   CONFIG_DIFFERS    a PDC stencil element has Allow JavaScript off or strips HTML, or
#                     is in the wrong view (the interactive component belongs on
#                     edit only, the read-only one on detail only)
#   AMBIGUOUS         an element's fingerprints match more than one PDC element; needs a human
#   DUPLICATE         the same PDC element appears more than once in one stencil
#   NO_THEMES         an active Integration Map with no Grant Request Themes (no grant uses it)
#   THEME_ON_SEVERAL_MAPS  a Grant Request Theme on more than one active Integration Map
#
# Saves the results to validate_results on this deploy model (rendered on the
# card by the Results block via PDC_Results), and returns them. Read-only
# otherwise.

require 'json'
require 'time'

lib = model.dyn_invoke_for(:"PDC Installer Lib") unless defined?(lib) && lib
# A pasted test script embeds the manifest and sets pdc_one_off.
save_now = defined?(pdc_one_off) && pdc_one_off ? true : false
record =
  begin
    manifest = (defined?(pdc_manifest) && pdc_manifest) || lib[:fetch_repo_json].call(model, 'deploy/pdc-manifest.json')
    # Get PDC Base URL is expected to hold the URL of the PDC Environment chosen here
    lib[:apply_environment].call(manifest, model)
    # Validate with the scope the manifest was built from, so fingerprints
    # and exclusions always agree with the hashes.
    live = lib[:collect].call(manifest['scope'], false)
    rows = lib[:validate].call(manifest, live, model) + lib[:map_theme_rows].call
    lib[:results_record].call('Validation', "read-only, against #{lib[:ref_label].call(model)}", rows,
                              'warnings' => Array(live['warnings']))
  rescue => e
    lib[:results_record].call('Validation', 'failed', [], 'error' => "#{e.class}: #{e.message}")
  end

# Inside a workflow-button hook the record is already being saved.
saved = lib[:store_results].call(model, 'validate_results', record, save_now)
"PDC Validation (#{record['mode']}; #{saved}): " + Array(record['summary']).map { |x| "#{x['label']} #{x['count']}" }.join(', ') +
  (record['error'] ? " || #{record['error']}" : '')
