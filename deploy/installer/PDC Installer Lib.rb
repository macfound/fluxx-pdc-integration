# PDC Installer Lib
#
# Shared helpers for the PDC deploy model's installer methods. Returns a Hash
# of lambdas, so every installer method starts with:
#
#   lib = model.dyn_invoke_for(:"PDC Installer Lib")
#
# Read-only except store_results (results fields), snapshot documents, and
# the permission probe (always rolled back).
#
# The normalize/hash rules below MUST stay identical to the ones in
# deploy/tools/pdc_manifest.rb, or every body will report DIFFERS.

require 'json'
require 'digest'
require 'net/http'
require 'uri'
require 'cgi'
require 'time'
require 'zlib'
require 'base64'
require 'securerandom'

lib = {}

# ---------------------------------------------------------------------------
# Normalizing and hashing
# ---------------------------------------------------------------------------

# CRLF vs LF and trailing whitespace are not meaningful drift for Ruby pasted
# through Fluxx's admin textareas. Blank counts as absent.
lib[:normalize] = lambda do |text|
  next nil if text.nil?
  out = text.to_s.gsub("\r\n", "\n").split("\n").map(&:rstrip).join("\n").strip
  out.empty? ? nil : out
end

lib[:sha] = lambda do |text|
  norm = lib[:normalize].call(text)
  norm && Digest::SHA256.hexdigest(norm)
end

# Stencil JSON is compared structurally: keys sorted, per-instance keys
# (scope "stencil_volatile_keys", e.g. element uids) dropped, and profile
# restrictions (scope "stencil_profile_keys") masked, because profile ids differ
# per instance. The admin's pdc_staff_profile choice is checked separately.
canon = nil
canon = lambda do |obj, volatile, masked|
  case obj
  when Hash
    obj.keys.sort.each_with_object({}) do |k, h|
      next if volatile.include?(k)
      h[k] = masked.include?(k) && !obj[k].nil? ? '<profile>' : canon.call(obj[k], volatile, masked)
    end
  when Array
    obj.map { |v| canon.call(v, volatile, masked) }
  else
    obj
  end
end

lib[:canonical_stencil] = lambda do |raw, volatile, masked = []|
  next nil if raw.nil? || raw.to_s.strip.empty?
  canon.call(JSON.parse(raw.to_s), volatile, masked)
end

# ascii_only: Fluxx's JSON escapes non-ASCII (e.g. \u2713) and plain Ruby
# doesn't, so force the escaped form on both sides.
# Show/hide conditions inside a stencil's "advanced_query" strings can name a
# dropdown option by id ([attribute, op, option_id]); ids differ per instance.
# rewrite_conditions passes each such value through fn.call(attribute, value)
# and keeps the string untouched when nothing changes.
rewrite_conditions = nil
rewrite_conditions = lambda do |obj, fn|
  case obj
  when Hash
    obj.each_with_object({}) do |(k, v), h|
      h[k] = if k == 'advanced_query' && v.is_a?(String)
               q = (JSON.parse(v) rescue nil)
               if q.is_a?(Hash)
                 changed = false
                 walk = nil
                 walk = lambda do |node|
                   next node unless node.is_a?(Array)
                   if node.size == 3 && node.all? { |x| x.is_a?(String) }
                     nv = fn.call(node[0], node[2])
                     next node if nv == node[2]
                     changed = true
                     next [node[0], node[1], nv]
                   end
                   node.map { |x| walk.call(x) }
                 end
                 out = q.merge('conditions' => walk.call(q['conditions']))
                 changed ? JSON.generate(out) : v
               else
                 v
               end
             else
               rewrite_conditions.call(v, fn)
             end
    end
  when Array then obj.map { |v| rewrite_conditions.call(v, fn) }
  else obj
  end
end
lib[:rewrite_conditions] = lambda { |obj, fn| rewrite_conditions.call(obj, fn) }

# This instance's option ids, as names ("option:<value>"), for the attributes the
# scope lists for a model type: { attribute => { id => name } }
lib[:live_option_names] = lambda do |scope, model_type|
  (scope['stencil_option_ids'] || {}).keys.each_with_object({}) do |key, h|
    mt, attr = key.split('.', 2)
    next unless mt == model_type
    field = ModelAttribute.where(model_type: mt, name: attr, deleted_at: nil).first
    h[attr] = field ? ModelAttributeValue.where(model_attribute_id: field.id).each_with_object({}) { |o, m| m[o.id.to_s] = o.value.to_s } : {}
  end
end

# Stencil hash; with names ({ attribute => { id => name } }) option ids in
# conditions are compared by name, as the manifest tool does with the repo copy
lib[:stencil_sha] = lambda do |raw, volatile, masked = [], names = {}|
  next nil if raw.nil? || raw.to_s.strip.empty?
  doc = JSON.parse(raw.to_s)
  doc = rewrite_conditions.call(doc, lambda { |attr, v| names[attr] && names[attr][v] ? "option:#{names[attr][v]}" : v }) unless names.empty?
  Digest::SHA256.hexdigest(JSON.generate(canon.call(doc, volatile, masked), ascii_only: true))
end

# Every value of the profile-restriction keys in a stencil, e.g. ["974"].
profile_values = nil
profile_values = lambda do |obj, keys|
  case obj
  when Hash then obj.flat_map { |k, v| keys.include?(k) ? Array(v).map(&:to_s) : profile_values.call(v, keys) }
  when Array then obj.flat_map { |v| profile_values.call(v, keys) }
  else []
  end
end
lib[:stencil_profiles] = lambda do |raw, keys|
  doc = (JSON.parse(raw.to_s) rescue nil)
  doc ? profile_values.call(doc, keys).reject(&:empty?).uniq : []
end

# The ###PDC_CODE###...###END_PDC_CODE### slice of a shared hook, markers
# included. nil when the markers aren't there.
lib[:code_slice] = lambda do |text, markers|
  src = text.to_s
  from = src.index(markers['code_start'])
  to = src.index(markers['code_end'])
  next nil if from.nil? || to.nil? || to < from
  src[from...(to + markers['code_end'].length)]
end

# ---------------------------------------------------------------------------
# Reading the public repo
# ---------------------------------------------------------------------------

# Where code comes from: the record's repo_url / repo_ref fields, else the
# "PDC Repo Settings" method the bootstrap writes (the fields can't always be
# set on the very first record).
lib[:repo_settings] = lambda do |deploy_model|
  saved = (deploy_model.dyn_invoke_for(:"PDC Repo Settings") rescue nil)
  saved = {} unless saved.is_a?(Hash)
  url = deploy_model.respond_to?(:repo_url) ? deploy_model.repo_url.to_s.strip : ''
  ref = deploy_model.respond_to?(:repo_ref) ? deploy_model.repo_ref.to_s.strip : ''
  url = saved['repo_url'].to_s if url.empty?
  ref = saved['repo_ref'].to_s if ref.empty?
  ref = 'main' if ref.empty?
  raise "repo_ref #{ref.inspect} isn't a branch, tag or commit name" unless ref =~ %r{\A[\w.\-/]+\z} && !ref.include?('..')
  { 'repo_url' => url, 'repo_ref' => ref }
end

lib[:repo_ref] = lambda { |deploy_model| lib[:repo_settings].call(deploy_model)['repo_ref'] }

# The commit repo_ref points to right now, looked up once per run (GitHub's
# API), so results can say which commit they ran from.
# Returns [sha, nil] or [nil, why it couldn't be looked up].
lib[:github_commit] = lambda do |repo_url, ref|
  next [ref, nil] if ref.to_s =~ /\A\h{40}\z/
  m = repo_url.to_s.strip.match(%r{github\.com[/:]([^/]+)/([^/]+?)(?:\.git)?/?\z})
  next [nil, "repo_url isn't a github.com repository"] unless m
  begin
    uri = URI.parse("https://api.github.com/repos/#{m[1]}/#{m[2]}/commits/#{ref}")
    req = Net::HTTP::Get.new(uri)
    req['Accept'] = 'application/vnd.github.sha'
    req['User-Agent'] = 'fluxx-pdc-installer'
    resp = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 20) { |http| http.request(req) }
    sha = resp.body.to_s.strip
    resp.code == '200' && sha =~ /\A\h{40}\z/ ? [sha, nil] : [nil, "GitHub answered HTTP #{resp.code}"]
  rescue => e
    [nil, "#{e.class}: #{e.message}"]
  end
end

lib[:repo_commit] = lambda do |deploy_model|
  rs = lib[:repo_settings].call(deploy_model)
  key = [rs['repo_url'], rs['repo_ref']]
  memo = deploy_model.instance_variable_get(:@pdc_repo_commit)
  next memo[1] if memo && memo[0] == key
  found = lib[:github_commit].call(rs['repo_url'], rs['repo_ref'])
  deploy_model.instance_variable_set(:@pdc_repo_commit, [key, found])
  found
end

# "main @ 8216643" (or just the ref when the commit couldn't be looked up)
lib[:ref_label] = lambda do |deploy_model|
  sha = lib[:repo_commit].call(deploy_model)[0]
  ref = lib[:repo_ref].call(deploy_model)
  sha && sha != ref ? "#{ref} @ #{sha[0, 7]}" : (sha ? sha[0, 7] : ref)
end

# "owner/repo@main @ 8216643", for results
lib[:repo_label] = lambda do |deploy_model|
  rs = lib[:repo_settings].call(deploy_model)
  m = rs['repo_url'].match(%r{github\.com[/:]([^/]+)/([^/]+?)(?:\.git)?/?\z})
  "#{m ? "#{m[1]}/#{m[2]}" : rs['repo_url']}@#{lib[:ref_label].call(deploy_model)}"
end

lib[:raw_url] = lambda do |repo_url, ref, path|
  m = repo_url.to_s.strip.match(%r{github\.com[/:]([^/]+)/([^/]+?)(?:\.git)?/?\z})
  raise "repo_url must be a github.com repository URL, got #{repo_url.inspect}" unless m
  encoded = path.split('/').map { |p| CGI.escape(p).gsub('+', '%20') }.join('/')
  "https://raw.githubusercontent.com/#{m[1]}/#{m[2]}/#{ref}/#{encoded}"
end

lib[:fetch_repo_file] = lambda do |deploy_model, path|
  rs = lib[:repo_settings].call(deploy_model)
  ref = rs['repo_ref']
  uri = URI.parse(lib[:raw_url].call(rs['repo_url'], ref, path))
  resp = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
    http.request(Net::HTTP::Get.new(uri))
  end
  unless resp.code == '200'
    raise "Could not fetch #{path} at ref '#{ref}' from #{rs['repo_url']} (HTTP #{resp.code}). Check repo_url and repo_ref."
  end
  resp.body.to_s.dup.force_encoding('UTF-8')
end

lib[:fetch_repo_json] = lambda do |deploy_model, path|
  JSON.parse(lib[:fetch_repo_file].call(deploy_model, path))
end

# ---------------------------------------------------------------------------
# Stencil element trees
# ---------------------------------------------------------------------------

# Flattens a stencil's element tree (groups nest their children under
# "elements"). Each entry keeps its index trail and its ancestor group labels.
flatten = nil
flatten = lambda do |elements, trail, parents|
  out = []
  Array(elements).each_with_index do |el, i|
    next unless el.is_a?(Hash)
    here = trail + [i]
    out << { 'element' => el, 'trail' => here, 'parents' => parents }
    if el['elements'].is_a?(Array)
      cfg = el['config'].is_a?(Hash) ? el['config'] : {}
      label = cfg['label'] || cfg['title'] || cfg['name'] || el['type']
      out.concat(flatten.call(el['elements'], here, parents + [label.to_s]))
    end
  end
  out
end

lib[:stencil_elements] = lambda do |raw_json|
  doc = begin
    JSON.parse(raw_json.to_s)
  rescue JSON::ParserError
    nil
  end
  doc.is_a?(Hash) ? flatten.call(doc['elements'], [], []) : []
end

# Element text as stored. TRN (2026-10-16) showed the database keeps it as
# typed (entities like &#10003; and "&amp;" inside JS survive), while older
# REST reads looked entity-encoded. So comparisons accept either the raw text
# or its HTML-decoded form.
lib[:element_text] = lambda do |el|
  cfg = el['config'].is_a?(Hash) ? el['config'] : {}
  cfg['text'].is_a?(String) ? cfg['text'] : nil
end

# Fluxx stores checkbox settings as true, "1", "0", etc.
lib[:truthy] = lambda do |v|
  v == true || v.to_s.strip =~ /\A(1|true|yes|on)\z/i ? true : false
end

# Required element settings (scope "element_required_config") that this element
# doesn't have, e.g. ["allow_script is off, needs on"].
lib[:element_config_problems] = lambda do |el, required|
  cfg = el['config'].is_a?(Hash) ? el['config'] : {}
  (required || {}).reject { |k, want| lib[:truthy].call(cfg[k]) == want }.map do |k, want|
    "#{k} is #{lib[:truthy].call(cfg[k]) ? 'on' : 'off'}, needs #{want ? 'on' : 'off'}"
  end
end

# Views an element must be in or out of (its scope "visibility": visible_form is
# the edit view, visible_show the detail view) that it isn't, e.g.
# ["visible_show is on, needs off"].
lib[:element_visibility_problems] = lambda do |el, want|
  vis = el['visibility'].is_a?(Hash) ? el['visibility'] : {}
  (want || {}).reject { |k, w| lib[:truthy].call(vis[k]) == w }.map do |k, w|
    "#{k} is #{lib[:truthy].call(vis[k]) ? 'on' : 'off'}, needs #{w ? 'on' : 'off'}"
  end
end

# Puts an element in or out of the views its scope "visibility" names. Fluxx
# leaves a view's key out when the element isn't shown there.
lib[:set_element_visibility] = lambda do |el, want|
  el['visibility'] = {} unless el['visibility'].is_a?(Hash)
  (want || {}).each { |k, w| w ? el['visibility'][k] = true : el['visibility'].delete(k) }
  el
end

# Saves a stencil's JSON and reads it back from the database: raises if what
# was stored isn't what was written (e.g. truncated).
lib[:write_stencil] = lambda do |stencil, raw|
  stencil['json'] = raw
  stencil.save!
  back = Stencil.where(id: stencil.id).pluck(:json).first.to_s
  raise "stencil #{stencil.id} did not save intact (#{back.bytesize} of #{raw.bytesize} bytes)" unless back == raw
end

lib[:form_types] = lambda do |stencil|
  ft = stencil.form_type
  ft.is_a?(Array) ? ft.map(&:to_s) : ft.to_s.split(/[,\s]+/)
end

# The profiles an element is restricted to (its visibility "user_profile"),
# as sorted id strings; [] means no restriction.
lib[:profiles_of] = lambda do |node|
  vis = node.is_a?(Hash) && node['visibility'].is_a?(Hash) ? node['visibility'] : {}
  Array(vis['user_profile']).map(&:to_s).reject(&:empty?).uniq.sort
end

# Finds every PDC element in host stencils: first by its PDC:ELEMENT marker,
# otherwise by the scope's include/exclude fingerprints. Returns
# { element_id => [location, ...] }.
lib[:locate_elements] = lambda do |scope, include_text = false|
  specs = scope['stencil_elements']
  marker_re = Regexp.new(scope['markers']['element_regex'])
  hosts = specs.flat_map { |s| s['host_model_types'] }.uniq
  # Prefilter in SQL on plain tokens; text with < or quotes is stored escaped.
  tokens = ['PDC:ELEMENT'] + specs.flat_map { |s| s['include'] }.select { |t| t =~ /\A[\w-]+\z/ }.uniq
  conn = Stencil.connection
  like = tokens.map { |t| "json LIKE #{conn.quote('%' + t + '%')}" }.join(' OR ')

  found = Hash.new { |h, k| h[k] = [] }
  Stencil.where(model_type: hosts, deleted_at: nil).where(like).each do |st|
    doc = (JSON.parse(st['json'].to_s) rescue {})
    lib[:stencil_elements].call(st['json']).each do |entry|
      text = lib[:element_text].call(entry['element'])
      next if text.nil?
      decoded = CGI.unescapeHTML(text)
      m = text.match(marker_re) || decoded.match(marker_re)
      ids =
        if m
          [m[1]]
        else
          specs.select do |s|
            s['host_model_types'].include?(st.model_type) &&
              [text, decoded].any? do |t|
                s['include'].all? { |f| t.include?(f) } && s['exclude'].none? { |f| t.include?(f) }
              end
          end.map { |s| s['id'] }
        end
      ids.each do |id|
        found[id] << {
          'stencil_id' => st.id,
          'stencil_name' => st.name,
          'model_type' => st.model_type,
          'model_theme_id' => st.model_theme_id,
          'enabled' => st.enabled ? true : false,
          'via' => m ? 'marker' : 'fingerprint',
          'also_matches' => ids - [id],
          'trail' => entry['trail'],
          'parent_groups' => entry['parents'],
          'sha256' => lib[:sha].call(text),
          'sha256_decoded' => lib[:sha].call(decoded),
          'config_problems' => lib[:element_config_problems].call(entry['element'], scope['element_required_config']) +
                               lib[:element_visibility_problems].call(entry['element'], (specs.find { |s| s['id'] == id } || {})['visibility']),
          'profiles' => lib[:profiles_of].call(entry['element'])
        }.merge(include_text ? { 'text' => text } : {})
        if entry['trail'].size > 1
          parent = entry['trail'][0..-2].inject(doc) { |n, i| n.is_a?(Hash) ? Array(n['elements'])[i] : nil }
          if parent.is_a?(Hash) && parent['element_type'] == 'group'
            found[id].last['group_trail'] = entry['trail'][0..-2]
            found[id].last['group_profiles'] = lib[:profiles_of].call(parent)
          end
        end
      end
    end
  end
  found
end

# Every active form a theme shows: enabled stencils whose form types include
# "form" (filters are excluded; Fluxx marks every stencil compiled, so that
# says nothing). A theme can have several, e.g. per user profile.
lib[:theme_forms] = lambda do |theme|
  Stencil.where(model_type: theme.model_type, model_theme_id: theme.id, deleted_at: nil).to_a
         .select { |st| st.enabled && lib[:form_types].call(st).include?('form') }
         .sort_by(&:id)
end



# The first GenericTemplate stencil on a profile's dashboard: UserProfile ->
# first dashboard template -> its cards -> the first /generic_templates/{id}.
lib[:dashboard_template_stencil] = lambda do |profile|
  ids = (profile.dashboard_template_ids rescue nil)
  ids = (JSON.parse(ids) rescue []) if ids.is_a?(String)
  dt = Array(ids).first && (DashboardTemplate.find_by(id: Array(ids).first) rescue nil)
  data = dt && (dt.data.is_a?(String) ? (JSON.parse(dt.data) rescue {}) : dt.data)
  next nil unless data.is_a?(Hash)
  id = Array(data['cards']).map { |c| c.is_a?(Hash) && c['detail'].is_a?(Hash) ? c['detail']['url'].to_s[%r{generic_templates/(\d+)}, 1] : nil }.compact.first
  id && Stencil.where(id: id.to_i, model_type: 'GenericTemplate', deleted_at: nil).first
end

# What Install adds to which forms: one entry per form, with the PDC element
# ids (and native fields) it lacks, plus notes for choices that are missing.
lib[:placement_plan] = lambda do |deploy_model, scope|
  rules = scope['placement'] || {}
  located = lib[:locate_elements].call(scope, false)
  on_form = lambda { |stencil_id| located.select { |_, locs| locs.any? { |l| l['stencil_id'] == stencil_id } }.keys }
  plan = []
  notes = []
  add = lambda do |stencil, set, why, _unused = false|
    present = on_form.call(stencil.id)
    missing = set - present
    fields = Array(scope['required_stencil_fields']).select do |req|
      req['model_type'] == stencil.model_type && set.include?(req['with_element']) &&
        lib[:stencil_elements].call(stencil['json']).none? { |e| e['element']['element_type'] == 'attribute' && e['element']['name'] == req['attribute'] }
    end.map { |req| req['attribute'] }
    entry = { 'stencil_id' => stencil.id, 'model_type' => stencil.model_type, 'where' => "stencil #{stencil.id} (#{stencil.name.to_s.strip}, #{why})",
              'elements' => missing, 'fields' => fields }
    plan << entry
  end
  interactive = lib[:selected_themes].call(deploy_model, :grant_request_themes)
  notes << 'no Grant Request Themes chosen, so no grant form gets the PDC component' if interactive.empty?
  interactive.each do |th|
    forms = lib[:theme_forms].call(th)
    notes << "theme #{th.name} has no active form" if forms.empty?
    forms.each { |st| add.call(st, rules['interactive'] || [], "theme #{th.name}", true) }
  end
  # The OAuth callback goes on the first dashboard page of every chosen grantee
  # profile (once per page, if several profiles share a dashboard)
  profiles = lib[:selected_profiles].call(deploy_model, :pdc_grantee_profile)
  notes << 'no PDC Grantee Profile chosen, so the OAuth callback page has no home' if profiles.empty?
  pages = {}
  profiles.each do |profile|
    gt = lib[:dashboard_template_stencil].call(profile)
    if gt.nil?
      notes << "#{profile.name}'s dashboard has no GenericTemplate card"
    else
      (pages[gt.id] ||= [gt, []])[1] << profile.name
    end
  end
  pages.each_value { |gt, names| add.call(gt, rules['dashboard'] || [], "#{names.join(', ')} dashboard") }
  { 'forms' => plan, 'notes' => notes }
end

# Stencil elements Install adds: text elements and native fields, in a group
lib[:new_element] = lambda do |kind, model_type, opts|
  vis = { 'visible_show' => true, 'visible_form' => true, 'advanced_filter' => '1',
          'advanced_query' => JSON.generate('group_type' => 'and', 'conditions' => [], 'relationship_filter_model_type' => model_type),
          'advanced_sort' => '[]' }
  vis['user_profile'] = opts['profiles'] if opts['profiles'].is_a?(Array) && opts['profiles'].any?
  base = { 'visibility' => vis, 'styling' => { 'alignment' => 'left' }, 'uid' => SecureRandom.uuid }
  case kind
  when 'text'
    lib[:set_element_visibility].call(base, opts['visibility'])
    base.merge('element_type' => 'text', 'name' => 'text', 'config' => { 'text' => opts['text'], 'strip_html' => '0', 'allow_script' => true })
  when 'field'
    if opts['template'].is_a?(Hash)
      # A copy of how the field sits on a known-good form, with a fresh uid
      el = JSON.parse(JSON.generate(opts['template'])).merge('uid' => SecureRandom.uuid)
      el['visibility'] = (el['visibility'] || {}).merge('user_profile' => opts['profiles']) if opts['profiles'].is_a?(Array) && opts['profiles'].any?
      el
    else
      base.merge('element_type' => 'attribute', 'name' => opts['name'], 'label' => opts['label'],
                 'config' => { 'label' => opts['label'], 'required' => '0' })
    end
  when 'group'
    base.merge('element_type' => 'group', 'name' => 'group', 'label' => opts['label'],
               'config' => { 'label' => opts['label'], 'collapsible' => '0', 'default_open' => '0', 'disable_lazy_load' => '0',
                             'hide_label' => '0', 'reveal_if_type' => 'show', 'show_in_toc' => '0' },
               'elements' => opts['elements'])
  end
end

# Native fields the PDC code needs on the same stencil as a PDC element (scope
# "required_stencil_fields"): one entry per stencil holding that element,
# saying whether the field is on it.
lib[:stencil_fields] = lambda do |scope, located, include_bodies|
  out = []
  Array(scope['required_stencil_fields']).each do |req|
    ids = Array(located[req['with_element']]).map { |l| l['stencil_id'] }.uniq
    next if ids.empty?
    Stencil.where(id: ids).each do |st|
      hit = lib[:stencil_elements].call(st['json']).find do |e|
        e['element']['element_type'] == 'attribute' && e['element']['name'] == req['attribute']
      end
      entry = { 'key' => "#{req['model_type']}.#{req['attribute']} @ stencil #{st.id} (#{st.name.to_s.strip})",
                'attribute' => req['attribute'], 'stencil_id' => st.id, 'present' => !hit.nil?,
                'enabled' => st.enabled ? true : false, 'profiles' => hit ? lib[:profiles_of].call(hit['element']) : [] }
      entry['trail'] = hit['trail'] if hit
      entry['element'] = hit['element'] if hit && include_bodies
      out << entry
    end
  end
  out
end

# ---------------------------------------------------------------------------
# Live snapshot
# ---------------------------------------------------------------------------

# Collects every in-scope PDC record in the same shape as
# deploy/pdc-manifest.json. Each code body becomes "<field>_sha256"; with
# include_bodies it also carries the normalized "<field>" text (for export).
lib[:collect] = lambda do |scope, include_bodies|
  volatile = scope['stencil_volatile_keys'] || []
  masked = scope['stencil_profile_keys'] || []
  owned = scope['owned_model_types'].keys
  gr = scope['grant_request']
  excluded = (scope['excluded_method_patterns'] || []).map { |p| Regexp.new(p) }
  secrets = scope['secret_methods'] || []
  runtime = scope['runtime_option_attributes'] || []
  live = Hash.new { |h, k| h[k] = [] }

  add_body = lambda do |entry, field, text|
    entry["#{field}_sha256"] = lib[:sha].call(text)
    entry[field] = lib[:normalize].call(text) if include_bodies && entry["#{field}_sha256"]
  end
  state_names = {}
  # A button can point at a soft-deleted state; name it so the button reports DIFFERS.
  state_name = lambda do |id|
    state_names[id] ||=
      if (s = MachineState.find_by(id: id)).nil? then "missing-state-#{id}"
      elsif s.respond_to?(:deleted_at) && s.deleted_at.present? then "#{s.name} (deleted)"
      else s.name
      end
  end

  # Models
  MachineModelType.where(model_type: owned, deleted_at: nil).each do |mt|
    live['models'] << { 'key' => mt.model_type, 'model_type' => mt.model_type, 'name' => mt.name,
                        'show_in_plus_menu' => mt.show_in_plus_menu ? true : false }
  end

  # Profile permissions on owned models (e.g. Grantee may view/update their own
  # Consent). Which profile holds them is instance-specific, so only the
  # permission itself is compared; profile names are reported.
  UserProfileRule.where(model_type: owned).to_a.group_by { |r| [r.model_type, r.permission_name] }.each do |(mt, perm), rules|
    live['permissions'] << {
      'key' => "#{mt}:#{perm}", 'model_type' => mt, 'permission_name' => perm,
      'allowed' => rules.any? { |r| r.allowed },
      'profiles' => rules.map { |r| (UserProfile.find_by(id: r.user_profile_id)&.name rescue nil) || r.user_profile_id.to_s }.sort
    }
  end

  # Attributes and static dropdown options (ModelAttributeValue).
  # ModelAttributeChoice is per-record data and is never read here.
  ModelAttribute.where(deleted_at: nil)
                .where('model_type IN (?) OR (model_type = ? AND name IN (?))', owned, gr['model_type'], gr['attributes'])
                .each do |a|
    key = "#{a.model_type}.#{a.name}"
    e = {
      'key' => key, 'model_type' => a.model_type, 'name' => a.name, 'description' => a.description,
      'attribute_type' => a.attribute_type, 'multi_allowed' => a.multi_allowed ? true : false,
      'value_model_type' => a.value_model_type
    }
    if a.attribute_type == 'multi_value'
      e['options'] =
        if runtime.include?(key)
          'runtime'
        else
          ModelAttributeValue.where(model_attribute_id: a.id, deleted_at: nil).order(:display_order, :id).map do |v|
            { 'value' => v.value, 'description' => v.description, 'display_order' => v.display_order, 'retired' => v.retired ? true : false }
          end
        end
    end
    live['attributes'] << e
  end

  # Methods: everything on owned models, plus GrantRequest methods with a PDC prefix
  ModelMethod.where(model_type: owned + [gr['model_type']], deleted_at: nil).each do |mm|
    next if mm.model_type == gr['model_type'] && gr['method_prefixes'].none? { |p| mm.name.start_with?(p) }
    next if excluded.any? { |re| mm.name =~ re }
    e = { 'key' => "#{mm.model_type}##{mm.name}", 'model_type' => mm.model_type, 'name' => mm.name, 'method_type' => mm.method_type }
    if secrets.include?(mm.name)
      e['secret'] = true
      # Only whether the value has been entered; the value itself is never read out
      e['configured'] = !mm.unsafe_dyn_method.to_s.include?('Not Configured')
    else
      add_body.call(e, 'body', mm.unsafe_dyn_method)
    end
    live['methods'] << e
  end

  # Themes -> workflows -> events
  ModelTheme.where(model_type: owned, deleted_at: nil).each do |t|
    # Portable theme settings only; ids (user_profile_ids, program_id, ...) differ per instance.
    e = { 'key' => "#{t.model_type}/#{t.name}", 'model_type' => t.model_type, 'name' => t.name, 'label' => t.label }
    %w[external_access_enabled limit_by_user_profile_flag hide_from_theme_switching request_may_be_grantee_user_only].each do |col|
      e[col] = t[col] ? true : false if t.has_attribute?(col)
    end
    add_body.call(e, 'before_new', t.unsafe_before_new_block)
    add_body.call(e, 'after_create', t.unsafe_after_create_block)
    live['themes'] << e

    MachineWorkflow.where(model_theme_id: t.id, deleted_at: nil).each do |w|
      live['workflows'] << { 'key' => "#{t.model_type}/#{t.name}", 'model_type' => t.model_type, 'theme' => t.name, 'name' => w.name }

      MachineEvent.where(machine_workflow_id: w.id, deleted_at: nil).each do |ev|
        ee = {
          'key' => "#{t.model_type}/#{t.name}>#{ev.button_name}", 'model_type' => t.model_type, 'theme' => t.name,
          'button_name' => ev.button_name, 'name' => ev.name, 'to_state' => state_name.call(ev.to_state_id),
          # The states the button shows on (its order there is Fluxx's own)
          'from_states' => MachineEventFromState.where(machine_event_id: ev.id)
                                                .map { |f| state_name.call(f.from_state_id).to_s }.uniq.sort,
          'is_validation_suppressed' => ev.is_validation_suppressed ? true : false,
          'guard_strategy' => ev.guard_strategy, 'filter' => ev.filter
        }
        add_body.call(ee, 'guard', ev.unsafe_guard)
        # Roles are the admin's choice per instance; reported, never part of the manifest.
        ee['roles'] = MachineEventRole.where(machine_event_id: ev.id).map do |r|
          (role = Role.find_by(id: r.role_id)) ? role.name : "missing-role-#{r.role_id}"
        end.sort
        live['events'] << ee
      end
    end
  end

  # States (one row per model type, shared by every theme)
  MachineState.where(model_type: owned, deleted_at: nil).each do |s|
    e = {
      'key' => "#{s.model_type}:#{s.name}", 'model_type' => s.model_type, 'name' => s.name,
      'description' => s.description, 'state_type' => s.state_type, 'state_order' => s.state_order,
      'allowed_roles' => s.allowed_roles
    }
    add_body.call(e, 'before_validation_enter', s.unsafe_before_validation_enter)
    add_body.call(e, 'after_enter', s.unsafe_after_enter)
    live['states'] << e
  end

  # Owned stencils: each owned model's form/list/show stencil (identical
  # copies left behind by imports are ignored)
  owned.each do |mt|
    cands = Stencil.where(model_type: mt, deleted_at: nil).to_a.select { |st| lib[:form_types].call(st).include?('form') }
    next if cands.empty?
    primary = cands.max_by { |st| [st.enabled ? 1 : 0, st.updated_at.to_i] }
    names = lib[:live_option_names].call(scope, mt)
    if cands.map { |st| lib[:stencil_sha].call(st['json'], volatile, masked, names) }.uniq.size > 1
      live['warnings'] << "#{cands.size} form stencils for #{mt} with different content (ids #{cands.map(&:id).join(', ')}); compared #{primary.id}"
    end
    e = { 'key' => "#{mt}:form", 'model_type' => mt, 'name' => primary.name }
    e['json_sha256'] = lib[:stencil_sha].call(primary['json'], volatile, masked, names)
    # Every element needs a uid or the record page renders blank; the repo copy
    # has none, so a form without them differs whatever its content
    no_uid = nil
    no_uid = lambda { |els| Array(els).any? { |x| x.is_a?(Hash) && (x['uid'].to_s.empty? || no_uid.call(x['elements'])) } }
    if no_uid.call((JSON.parse(primary['json'].to_s)['elements'] rescue nil))
      e['json_sha256'] = "#{e['json_sha256']} (elements without a uid)"
      live['warnings'] << "form stencil #{primary.id} for #{mt} has elements without a uid, so the record page shows blank: click Install"
    end
    # Raw JSON for export (the repo keeps real profile ids for reference); masked for hashing.
    e['json'] = JSON.parse(primary['json']) if include_bodies
    e['profiles'] = lib[:stencil_profiles].call(primary['json'], masked).map do |id|
      (UserProfile.find_by(id: id.to_i)&.name rescue nil) || id
    end
    live['stencils'] << e
  end
  # Shared GrantRequest hooks: only the marker slice is PDC's
  gr['shared_state_hooks'].each do |h|
    st = MachineState.where(model_type: gr['model_type'], name: h['state'], deleted_at: nil).first
    next if st.nil?
    e = { 'key' => "#{gr['model_type']}:#{h['state']}:#{h['field']}", 'model_type' => gr['model_type'], 'state' => h['state'], 'field' => h['field'] }
    slice = lib[:code_slice].call(st[h['field']], scope['markers'])
    if slice
      add_body.call(e, 'body', slice)
    else
      e['marker_found'] = false
    end
    live['shared_slices'] << e
  end

  # Stencil elements inside stencils PDC doesn't own
  located = lib[:locate_elements].call(scope, include_bodies)
  scope['stencil_elements'].each do |spec|
    live['stencil_elements'] << { 'key' => spec['id'], 'id' => spec['id'], 'locations' => located[spec['id']] }
  end
  # A marker whose id isn't one of this release's elements (e.g. an older id)
  (located.keys - scope['stencil_elements'].map { |s| s['id'] }).each do |id|
    where = located[id].map { |l| "stencil #{l['stencil_id']} (#{l['stencil_name'].to_s.strip})" }.uniq.join(', ')
    live['warnings'] << "PDC:ELEMENT marker id=#{id} on #{where} isn't a PDC element this release knows, so it's left alone"
  end
  live['stencil_fields'] = lib[:stencil_fields].call(scope, located, include_bodies)

  live
end

# ---------------------------------------------------------------------------
# Comparing manifest vs live
# ---------------------------------------------------------------------------

# Manifest keys that are bookkeeping, not something to compare.
skip_key = lambda do |k|
  %w[key secret roles profiles locations marker_found].include?(k) || k.end_with?('_path')
end

short = lambda do |v|
  s = v.is_a?(String) ? v : JSON.generate(v)
  s.length > 160 ? "#{s[0, 160]}..." : s
end

# The option values (record ids, as strings) chosen in one of the deploy
# model's dropdowns. Fluxx may hand back option rows, option ids, values or
# labels, so each is matched against that field's options.
lib[:selected_values] = lambda do |deploy_model, attr|
  next [] unless deploy_model.respond_to?(attr)
  raw = Array(deploy_model.public_send(attr)).flatten.compact
  field = ModelAttribute.where(model_type: deploy_model.class.name, name: attr.to_s, deleted_at: nil).first
  options = field ? ModelAttributeValue.where(model_attribute_id: field.id).to_a : []
  raw.map do |v|
    next v.value.to_s if v.respond_to?(:value) && v.respond_to?(:model_attribute_id)
    s = v.to_s.strip
    next nil if s.empty?
    hit = options.find { |o| o.id.to_s == s } || options.find { |o| o.value.to_s == s } || options.find { |o| o.description.to_s == s }
    hit ? hit.value.to_s : s
  end.compact.uniq
end

# Every Role / UserProfile chosen in one of the deploy model's multi-select
# fields (Installer Role, PDC Event Role, PDC Grantee Profile, PDC Staff
# Profile), in the order chosen
lib[:selected_roles] = lambda do |deploy_model, attr = :pdc_event_role|
  lib[:selected_values].call(deploy_model, attr).map do |v|
    Role.where(id: v.to_i, deleted_at: nil).first || Role.where(name: v, deleted_at: nil).first
  end.compact.uniq
end

lib[:selected_profiles] = lambda do |deploy_model, attr|
  live = UserProfile.column_names.include?('deleted_at') ? UserProfile.where(deleted_at: nil) : UserProfile.all
  lib[:selected_values].call(deploy_model, attr).map do |v|
    live.where(id: v.to_i).first || live.where(name: v).first
  end.compact.uniq
end

lib[:selected_role] = lambda { |deploy_model, attr = :pdc_event_role| lib[:selected_roles].call(deploy_model, attr).first }
lib[:selected_profile] = lambda { |deploy_model, attr| lib[:selected_profiles].call(deploy_model, attr).first }

lib[:selected_themes] = lambda do |deploy_model, attr|
  lib[:selected_values].call(deploy_model, attr).map { |v| ModelTheme.where(id: v.to_i, deleted_at: nil).first }.compact
end

# Which PDC this instance talks to. The admin chooses it in the deploy model's
# PDC Environment field (options from PDC Populate Options); Install writes the
# matching URL into Get PDC Base URL. Nothing else in Fluxx says whether an
# instance is production or a sandbox.
lib[:pdc_environments] = {
  'production' => { 'label' => 'Production', 'url' => 'https://api.philanthropydatacommons.org' },
  'sandbox'    => { 'label' => 'Sandbox',    'url' => 'https://api.sandbox.philanthropydatacommons.org' }
}
lib[:base_url_method] = 'Get PDC Base URL'

# The whole Get PDC Base URL body for one URL. The repo copy
# (pdc-map/pdc-integration-map/Get PDC Base URL.rb) is this with the sandbox URL.
lib[:base_url_body] = lambda do |url|
  "# Get PDC Base URL\n" \
  "# Which PDC this Fluxx instance talks to. Written by the PDC installer from the\n" \
  "# PDC Environment chosen on the PDC deploy record: to switch between Production\n" \
  "# and Sandbox, change it there and click Install. Edits made here are\n" \
  "# overwritten by the next Install.\n" \
  "#{url.inspect}"
end

# Active PDC Integration Maps and their Grant Request Themes. A grant uses the
# active map that lists its theme, so a map with no themes is used by no grant
# (NO_THEMES) and a theme on two active maps stops its grants from sending
# (THEME_ON_SEVERAL_MAPS). Empty until Install has put the maps' theme method in.
lib[:map_theme_rows] = lambda do
  klass = 'MacModelTypeDynPdcApplicationForm1'.safe_constantize
  next [] if klass.nil? || !ModelMethod.where(model_type: klass.name, name: 'Get Grant Request Theme Ids', deleted_at: nil).exists?
  rows = []
  by_theme = Hash.new { |h, k| h[k] = [] }
  klass.where(state: 'active', deleted_at: nil).each do |map|
    name = map.get_dyn_value(:name).presence || "map #{map.id}"
    ids = map.dyn_invoke_for(:"Get Grant Request Theme Ids")
    if ids.empty?
      rows << { 'kind' => 'maps', 'key' => name, 'status' => 'NO_THEMES',
                'detail' => ['no Grant Request Themes chosen, so no grant uses this map'] }
    end
    ids.each { |id| by_theme[id] << name }
  end
  by_theme.each do |id, names|
    next if names.size < 2
    theme = ModelTheme.find_by(id: id.to_i)&.name || "theme #{id}"
    rows << { 'kind' => 'maps', 'key' => theme, 'status' => 'THEME_ON_SEVERAL_MAPS',
              'detail' => ["on #{names.join(', ')}: its grants can't be sent until only one active map has it"] }
  end
  rows
end

# Points a bundle's or manifest's Get PDC Base URL entry at the environment
# chosen on deploy_model: its body (bundle) and body_sha256 (manifest). With
# none chosen the entry is flagged environment_missing, so Install leaves the
# method as it is and Validate reports NOT_CONFIGURED.
lib[:apply_environment] = lambda do |components, deploy_model|
  entry = Array(components['methods']).find { |m| m['name'] == lib[:base_url_method] }
  next components if entry.nil?
  env = lib[:selected_values].call(deploy_model, :pdc_environment).map { |v| lib[:pdc_environments][v] }.compact.first
  if env.nil?
    entry['environment_missing'] = true
    next components
  end
  body = lib[:base_url_body].call(env['url'])
  entry['body'] = body if entry.key?('body')
  entry['body_sha256'] = lib[:sha].call(body) if entry.key?('body_sha256')
  components
end

# Returns report rows: { kind, key, status, detail }.
# Statuses: MATCH, DIFFERS, MISSING, EXTRA, SKIPPED_SECRET, MARKER_NOT_FOUND,
# MISSING_ROLE, ROLE_DIFFERS, PROFILE_DIFFERS, UNMARKED, UNMARKED_DIFFERS,
# CONFIG_DIFFERS, SKIPPED_SWITCHED_OFF, AMBIGUOUS, DUPLICATE.
lib[:validate] = lambda do |manifest, live, deploy_model|
  # (statuses also include NOT_CONFIGURED: a secret method still holding its
  # placeholder, or Get PDC Base URL with no PDC Environment chosen)
  rows = []
  row = lambda { |kind, key, status, detail = nil| rows << { 'kind' => kind, 'key' => key, 'status' => status, 'detail' => detail }.compact }
  wanted_roles = lib[:selected_roles].call(deploy_model, :pdc_event_role).map(&:name).sort
  wanted_grantees = lib[:selected_profiles].call(deploy_model, :pdc_grantee_profile).map(&:name).sort
  wanted_staff = lib[:selected_profiles].call(deploy_model, :pdc_staff_profile).map(&:name).sort

  %w[models permissions attributes methods themes states workflows events stencils shared_slices].each do |kind|
    by_key = {}
    Array(live[kind]).each { |l| by_key[l['key']] = JSON.parse(JSON.generate(l)) }
    seen = {}

    Array(manifest[kind]).each do |m|
      key = m['key']
      seen[key] = true
      l = by_key[key]
      if l.nil?
        row.call(kind, key, 'MISSING')
        next
      end
      if m['environment_missing']
        row.call(kind, key, 'NOT_CONFIGURED', ['no PDC Environment chosen on the deploy record: choose Production or Sandbox, then Install'])
        next
      end
      if m['secret']
        if l['configured'] == false
          row.call(kind, key, 'NOT_CONFIGURED', ["still the placeholder: replace Not Configured with this instance's value, keeping the quotes"])
        else
          row.call(kind, key, 'SKIPPED_SECRET')
        end
        next
      end
      if l['marker_found'] == false
        row.call(kind, key, 'MARKER_NOT_FOUND')
        next
      end

      diffs = m.keys.reject { |k| skip_key.call(k) }.reject { |k| m[k] == l[k] }.map do |k|
        k.end_with?('_sha256') ? k.sub(/_sha256\z/, '') : "#{k}: expected #{short.call(m[k])}, found #{short.call(l[k])}"
      end
      diffs.empty? ? row.call(kind, key, 'MATCH') : row.call(kind, key, 'DIFFERS', diffs)

      missing_grantees = wanted_grantees - Array(l['profiles'])
      if kind == 'permissions' && missing_grantees.any?
        row.call(kind, key, 'PROFILE_DIFFERS', ["missing for #{missing_grantees.join(', ')}; held by #{Array(l['profiles']).join(', ')}"])
      end
      if kind == 'stencils' && wanted_staff.any? && Array(l['profiles']).any? && Array(l['profiles']).sort != wanted_staff
        row.call(kind, key, 'PROFILE_DIFFERS', ["restricted to #{Array(l['profiles']).join(', ')}, expected #{wanted_staff.join(', ')}"])
      end
      if kind == 'events'
        roles = Array(l['roles'])
        if roles.empty?
          row.call(kind, key, 'MISSING_ROLE', wanted_roles.any? ? ["expected #{wanted_roles.join(', ')}"] : nil)
        elsif wanted_roles.any? && roles.uniq.sort != wanted_roles
          row.call(kind, key, 'ROLE_DIFFERS', ["expected #{wanted_roles.join(', ')}, found #{roles.join(', ')}"])
        end
      end
    end

    next if kind == 'shared_slices'
    by_key.each_key { |key| row.call(kind, key, 'EXTRA') unless seen[key] }
  end

  # Who should see the PDC pieces on grant forms and the dashboard page: the
  # PDC Grantee Profiles chosen on the deploy record (checked on active forms)
  grantee_ids = lib[:selected_profiles].call(deploy_model, :pdc_grantee_profile).map { |pr| pr.id.to_s }.sort
  profile_names = lambda { |ids| ids.empty? ? 'everyone' : ids.map { |i| UserProfile.find_by(id: i.to_i)&.name || i }.join(', ') }

  # Required native fields on the stencils holding PDC elements
  Array(live['stencil_fields']).each do |f|
    row.call('stencil_fields', f['key'], f['present'] ? 'MATCH' : 'MISSING',
             f['present'] ? nil : ["#{f['attribute']} is not on this form; the PDC code reads it"])
    if f['present'] && f['enabled'] && grantee_ids.any? && Array(f['profiles']) != grantee_ids
      row.call('stencil_fields', f['key'], 'PROFILE_DIFFERS', ["shown to #{profile_names.call(Array(f['profiles']))}, expected #{profile_names.call(grantee_ids)}"])
    end
  end

  # The deploy model's own buttons: the Installer Roles chosen on it
  installer_roles = lib[:selected_roles].call(deploy_model, :installer_role).map(&:name).sort
  dtheme = ModelTheme.where(model_type: deploy_model.class.name, deleted_at: nil).order(:id).first
  dwf = dtheme && MachineWorkflow.where(model_theme_id: dtheme.id, deleted_at: nil).first
  if dwf && installer_roles.any?
    MachineEvent.where(machine_workflow_id: dwf.id, deleted_at: nil).each do |ev|
      have = Role.where(id: MachineEventRole.where(machine_event_id: ev.id).select(:role_id)).pluck(:name).sort
      row.call('installer_buttons', "#{deploy_model.class.name}>#{ev.button_name}", have == installer_roles ? 'MATCH' : 'ROLE_DIFFERS',
               have == installer_roles ? nil : ["expected #{installer_roles.join(', ')}, found #{have.empty? ? 'none' : have.join(', ')} (Update Installer fixes this)"])
    end
  end

  reported_groups = {}
  live_elements = {}
  Array(live['stencil_elements']).each { |l| live_elements[l['key']] = l }
  Array(manifest['stencil_elements']).each do |m|
    locs = Array((live_elements[m['key']] || {})['locations'])
    if locs.empty?
      row.call('stencil_elements', m['key'], 'MISSING')
      next
    end
    locs.group_by { |loc| loc['stencil_id'] }.each do |stencil_id, here|
      where = "#{m['key']} @ stencil #{stencil_id} (#{here.first['stencil_name']})"
      here.each do |loc|
        problems = Array(loc['config_problems'])
        next if problems.empty?
        # Install never changes a switched-off grant form (it's a rollback)
        if !loc['enabled'] && loc['model_type'] == manifest['scope']['grant_request']['model_type']
          row.call('stencil_elements', where, 'SKIPPED_SWITCHED_OFF', ['switched-off grant form (a rollback), so Install leaves it alone'] + problems)
        else
          row.call('stencil_elements', where, 'CONFIG_DIFFERS', problems)
        end
      end
      groups = here.map { |loc| loc['parent_groups'] }.uniq
      if grantee_ids.any?
        here.select { |loc| loc['enabled'] }.each do |loc|
          if Array(loc['profiles']) != grantee_ids
            row.call('stencil_elements', where, 'PROFILE_DIFFERS', ["element shown to #{profile_names.call(Array(loc['profiles']))}, expected #{profile_names.call(grantee_ids)}"])
          end
          gkey = [loc['stencil_id'], loc['group_trail']]
          if loc['group_trail'] && !reported_groups[gkey] && Array(loc['group_profiles']) != grantee_ids
            reported_groups[gkey] = true
            row.call('stencil_elements', "PDC group @ stencil #{loc['stencil_id']} (#{loc['stencil_name'].to_s.strip})", 'PROFILE_DIFFERS',
                     ["group shown to #{profile_names.call(Array(loc['group_profiles']))}, expected #{profile_names.call(grantee_ids)}"])
          end
        end
      end
      if here.any? { |loc| Array(loc['also_matches']).any? }
        row.call('stencil_elements', where, 'AMBIGUOUS', here.map { |loc| "trail #{loc['trail'].inspect} also looks like #{loc['also_matches'].join(', ')}" })
      elsif here.size > 1
        row.call('stencil_elements', where, 'DUPLICATE', here.map { |loc| "copy at trail #{loc['trail'].inspect} in groups: #{loc['parent_groups'].join(' > ')}" })
      elsif here.first['via'] == 'fingerprint'
        # No marker yet, but the content can still be compared with the repo
        # copy minus its marker line.
        same = m['unmarked_sha256'] && [here.first['sha256'], here.first['sha256_decoded']].include?(m['unmarked_sha256'])
        row.call('stencil_elements', where, same ? 'UNMARKED' : 'UNMARKED_DIFFERS',
                 ["#{same ? 'content matches the repo' : 'content differs from the repo'}; groups: #{groups.first.join(' > ')}"])
      elsif [here.first['sha256'], here.first['sha256_decoded']].include?(m['sha256'])
        row.call('stencil_elements', where, 'MATCH')
      else
        row.call('stencil_elements', where, 'DIFFERS', ['body'])
      end
    end
  end

  rows
end

# Exports travel through Fluxx's console, which collapses runs of spaces and
# re-escapes quotes and newlines. A single deflated base64 line survives that
# untouched; deploy/tools/pdc_manifest.rb unpacks it.
lib[:pack_export] = lambda do |data|
  'PDCEXPORT1:' + Base64.strict_encode64(Zlib::Deflate.deflate(JSON.generate(data), Zlib::BEST_COMPRESSION))
end

# ---------------------------------------------------------------------------
# Results shown on the deploy model card
# ---------------------------------------------------------------------------

# Colour group for a status, used by the Liquid results block.
results_tone = lambda do |status|
  st = status.to_s.downcase
  if st =~ /\A(match|ok)\z/ then 'good'
  elsif st =~ /would|skipped|kept|\Aunmarked\z|\Anote\z|\Asource\z|already gone|not shipped/ then 'info'
  elsif st =~ /\A(restored|created|recreated|overwrote|wrote|removed|cleared)/ then 'done'
  else 'bad'
  end
end

# One run's results, shaped for Liquid: summary counts per status, and the
# items for every status except MATCH/ok. entries: [{ 'status', 'kind', 'key', 'detail' }]
lib[:results_record] = lambda do |title, mode, entries, extra = {}|
  groups = entries.group_by { |e| e['status'] }
  {
    'title' => title, 'mode' => mode, 'ran_at' => Time.now.utc.iso8601,
    'summary' => groups.map { |st, es| { 'label' => st, 'count' => es.size, 'tone' => results_tone.call(st) } }.sort_by { |x| x['label'] },
    'groups' => groups.reject { |st, _| %w[MATCH ok].include?(st) }.map do |st, es|
      { 'label' => st, 'tone' => results_tone.call(st),
        'items' => es.map { |e| { 'kind' => e['kind'], 'key' => e['key'], 'detail' => Array(e['detail']).join('; ') } } }
    end.sort_by { |g| g['label'] }
  }.merge(extra)
end

# Turns an install-style log ({ status => [keys] }) into results entries.
lib[:log_entries] = lambda do |log|
  log.flat_map { |status, keys| keys.map { |k| { 'status' => status, 'key' => k } } }
end

# Saves a results record to a text field on the deploy model, creating the
# field if needed. save: true when run outside a save (a pasted script);
# false inside a workflow-button hook, where the record is already being saved.
lib[:store_results] = lambda do |deploy_model, field, record, save|
  begin
    rec = deploy_model
    unless rec.respond_to?("#{field}=")
      ModelAttribute.create!(model_type: rec.class.name, name: field, attribute_type: 'text', multi_allowed: false,
                             description: field.split('_').map(&:capitalize).join(' '))
      rec = rec.class.find(rec.id)
    end
    rec.public_send("#{field}=", JSON.generate(record))
    rec.save! if save
    "saved to #{field}"
  rescue => e
    "could not save to #{field}: #{e.class}: #{e.message}"
  end
end

# ---------------------------------------------------------------------------
# Configuration snapshots (previous_configuration / current_configuration)
# ---------------------------------------------------------------------------
#
# Install, Uninstall and Restore Previous each save a snapshot of every PDC
# component before they change anything and after. Each snapshot is a text
# document (ModelDocument, type "Snapshot") on the deploy record, so size
# isn't a concern (the GrantRequest forms alone are ~1.6 MB) and every
# snapshot is kept. previous_configuration / current_configuration hold a
# small pointer: the document id plus a readable header. Restore Previous
# follows previous_configuration's pointer.
#
# A snapshot is a list of records. Each one names a component by its natural
# key ('find'), and holds its id, whether it was soft-deleted, and the
# columns PDC writes ('cols'). id nil means the component didn't exist, so a
# restore soft-deletes it if it exists by then. Secret methods keep only id
# and deleted state, never their body.

snapshot_cols = {
  'MachineModelType' => %w[name show_in_plus_menu],
  'MachineWorkflow' => %w[name],
  'UserProfileRule' => %w[allowed],
  'ModelAttribute' => %w[description attribute_type multi_allowed value_model_type],
  'ModelAttributeValue' => %w[description display_order retired],
  'ModelMethod' => %w[method_type unsafe_dyn_method],
  'ModelTheme' => %w[label unsafe_before_new_block unsafe_after_create_block],
  'MachineState' => %w[description state_type state_order allowed_roles unsafe_before_validation_enter unsafe_after_enter],
  'MachineEvent' => %w[name is_validation_suppressed guard_strategy filter unsafe_guard],
  'Stencil' => %w[json enabled]
}.freeze
lib[:snapshot_cols] = snapshot_cols

# Snapshot targets for everything the bundle describes, in the order a
# restore applies them. Stencils are the ones holding PDC elements or PDC
# fields right now, plus any extra ids (e.g. those in an earlier snapshot).
lib[:snapshot_targets] = lambda do |bundle, extra_stencil_ids = [], extra_targets = []|
  t = []
  Array(bundle['models']).each do |m|
    t << { 'table' => 'MachineModelType', 'key' => "model #{m['model_type']}", 'find' => { 'model_type' => m['model_type'] } }
  end
  bundle['attributes'].each do |a|
    t << { 'table' => 'ModelAttribute', 'key' => a['key'], 'find' => { 'model_type' => a['model_type'], 'name' => a['name'] } }
    next unless a['options'].is_a?(Array)
    a['options'].each do |o|
      t << { 'table' => 'ModelAttributeValue', 'key' => "#{a['key']} = #{o['value']}",
             'find' => { 'model_type' => a['model_type'], 'attribute' => a['name'], 'value' => o['value'] } }
    end
  end
  bundle['methods'].each do |m|
    t << { 'table' => 'ModelMethod', 'key' => m['key'], 'find' => { 'model_type' => m['model_type'], 'name' => m['name'] } }
         .merge(m['secret'] ? { 'secret' => true } : {})
  end
  bundle['themes'].each do |th|
    t << { 'table' => 'ModelTheme', 'key' => th['key'], 'find' => { 'model_type' => th['model_type'], 'name' => th['name'] } }
  end
  Array(bundle['workflows']).each do |w|
    t << { 'table' => 'MachineWorkflow', 'key' => "workflow #{w['key']}", 'find' => { 'model_type' => w['model_type'], 'theme' => w['theme'] } }
  end
  bundle['states'].each do |s|
    t << { 'table' => 'MachineState', 'key' => s['key'], 'find' => { 'model_type' => s['model_type'], 'name' => s['name'] } }
  end
  bundle['events'].each do |e|
    t << { 'table' => 'MachineEvent', 'key' => e['key'], 'find' => { 'model_type' => e['model_type'], 'theme' => e['theme'], 'button_name' => e['button_name'] } }
  end
  bundle['shared_slices'].each do |x|
    t << { 'table' => 'MachineState', 'key' => x['key'], 'cols_only' => true, 'only_cols' => [x['field']],
           'find' => { 'model_type' => x['model_type'], 'name' => x['state'] } }
  end
  scope = bundle['scope']
  gr = scope['grant_request']
  ids = lib[:locate_elements].call(scope, false).values.flatten.map { |l| l['stencil_id'] }
  conn = Stencil.connection
  gr['attributes'].each do |name|
    Stencil.where(model_type: gr['model_type'], deleted_at: nil).where("json LIKE #{conn.quote('%' + name + '%')}").each do |st|
      ids << st.id if lib[:stencil_elements].call(st['json']).any? { |e| e['element']['element_type'] == 'attribute' && e['element']['name'] == name }
    end
  end
  (ids + extra_stencil_ids).uniq.sort.each do |id|
    t << { 'table' => 'Stencil', 'key' => "stencil #{id}", 'find' => { 'id' => id } }
  end
  # Every live form of the PDC models, by id (Install removes leftover copies)
  Stencil.where(model_type: bundle['scope']['owned_model_types'].keys, deleted_at: nil).pluck(:id).each do |id|
    t << { 'table' => 'Stencil', 'key' => "stencil #{id}", 'find' => { 'id' => id } } unless t.any? { |x| x['find'] == { 'id' => id } }
  end
  t + extra_targets
end

lib[:snapshot_class] = lambda do |table|
  raise "not a snapshot table: #{table}" unless snapshot_cols.key?(table)
  Object.const_get(table)
end

# Scope for a target's natural key. Events and dropdown options are found
# through their workflow / field. nil when that parent doesn't exist.
lib[:snapshot_scope] = lambda do |target|
  f = target['find']
  case target['table']
  when 'Stencil'
    # By id, or (for a PDC copy that may not exist yet) by theme and name
    f['id'] ? Stencil.where(id: f['id']) : Stencil.where(f.slice('model_type', 'model_theme_id', 'name'))
  when 'MachineWorkflow'
    themes = ModelTheme.where(model_type: f['model_type'], name: f['theme'])
    theme = themes.where(deleted_at: nil).first || themes.where.not(deleted_at: nil).order(deleted_at: :desc).first
    theme && MachineWorkflow.where(model_theme_id: theme.id)
  when 'UserProfileRule'
    UserProfileRule.where(f.slice('model_type', 'permission_name', 'user_profile_id'))
  when 'ModelAttributeValue'
    # The live field, else its latest soft-deleted one: options stay findable
    # while their field is removed (e.g. after Uninstall)
    fields = ModelAttribute.where(model_type: f['model_type'], name: f['attribute'])
    attr = fields.where(deleted_at: nil).first || fields.where.not(deleted_at: nil).order(deleted_at: :desc).first
    attr && ModelAttributeValue.where(model_attribute_id: attr.id, value: f['value'])
  when 'MachineEvent'
    theme = ModelTheme.where(model_type: f['model_type'], name: f['theme'], deleted_at: nil).first
    wf = theme && MachineWorkflow.where(model_theme_id: theme.id, deleted_at: nil).first
    wf && MachineEvent.where(machine_workflow_id: wf.id, button_name: f['button_name'])
  else
    lib[:snapshot_class].call(target['table']).where(f.slice('model_type', 'name'))
  end
end

# The live record for a target, else its most recently soft-deleted one.
lib[:snapshot_find] = lambda do |target, live_only = false|
  rel = lib[:snapshot_scope].call(target)
  next nil if rel.nil?
  next rel.first if target['table'] == 'Stencil' && target['find']['id']
  next rel.first unless rel.klass.column_names.include?('deleted_at')
  live = rel.where(deleted_at: nil).first
  next live if live || live_only
  rel.where.not(deleted_at: nil).order(deleted_at: :desc).first
end

# A button's target and from-states by state id and name (the name is the
# fallback if that state row is ever hard-deleted), and its role ids.
# Saves a button with the given roles and from-states. Fluxx won't save a
# button that has no role, so missing links are attached before the save.
lib[:save_event] = lambda do |ev, role_ids, from_ids|
  have_roles = ev.new_record? ? [] : MachineEventRole.where(machine_event_id: ev.id).pluck(:role_id)
  # Fluxx validates the button's roles list, so assign roles (the link rows are
  # created on save)
  ev.roles = Role.where(id: role_ids).to_a if have_roles.empty? && role_ids.any?
  if ev.new_record?
    from_ids.each { |sid| ev.machine_event_from_states.build(from_state_id: sid) }   # Fluxx sets the order
  end
  ev.save!
  ev
end

# Snapshots taken before the button order was dropped hold [name, order, id]
lib[:links_from] = lambda { |links| Array(links && links['from']).map { |x| [x.first, x.last] }.uniq.sort_by { |p| [p[0].to_s, p[1].to_i] } }
lib[:same_links] = lambda do |a, b|
  a.is_a?(Hash) && b.is_a?(Hash) && a.reject { |k, _| k == 'from' } == b.reject { |k, _| k == 'from' } && lib[:links_from].call(a) == lib[:links_from].call(b)
end

lib[:event_links] = lambda do |ev|
  name = lambda { |id| MachineState.find_by(id: id)&.name }
  { 'to_state' => name.call(ev.to_state_id), 'to_state_id' => ev.to_state_id,
    'from' => MachineEventFromState.where(machine_event_id: ev.id).map { |f| [name.call(f.from_state_id), f.from_state_id] }.uniq.sort_by { |p| [p[0].to_s, p[1].to_i] },
    'roles' => MachineEventRole.where(machine_event_id: ev.id).pluck(:role_id).sort }
end

# Configuration rows Fluxx soft-deletes along with a model (every config row
# naming the model type, as MachineModelType's handle_deletion_of_related_config
# does: labels, relationship mappings, fields elsewhere that point at it...),
# so a restore can bring back exactly the ones that were live:
# { model_type => { "table.column" => [ids] } }. Records and their documents
# are not included: Restore Previous only handles configuration.
lib[:capture_cascade] = lambda do |model_types|
  conn = ActiveRecord::Base.connection
  rel_cols = (MachineModelType::MODEL_TYPE_RELATION_COLUMN_NAMES rescue ['model_type'])
  # Fluxx's own list of configuration tables; else the tables seen holding PDC config on TRN
  tables = (Client.saas_tables rescue nil) ||
           %w[model_attributes model_methods model_themes machine_workflows machine_states stencils user_profile_rules
              field_labels field_lists field_stats relationship_schema_mappings]
  tables = (tables - ['machine_model_types']).select { |t| conn.table_exists?(t) rescue false }
  ids_where = lambda do |t, col, value|
    conn.select_values("SELECT id FROM #{conn.quote_table_name(t)} WHERE #{conn.quote_column_name(col)} = #{conn.quote(value)} AND deleted_at IS NULL").map(&:to_i)
  end
  model_types.each_with_object({}) do |mt, out|
    per = {}
    tables.each do |t|
      cols = (conn.columns(t).map(&:name) rescue [])
      next unless cols.include?('deleted_at') && cols.include?('id')
      (rel_cols & cols).each do |col|
        ids = ids_where.call(t, col, mt)
        per["#{t}.#{col}"] = ids unless ids.empty?
      end
    end
    out[mt] = per
  end
end

# Un-deletes captured rows that are soft-deleted now. Returns how many.
lib[:restore_cascade] = lambda do |per|
  conn = ActiveRecord::Base.connection
  per.sum do |table_col, ids|
    table = table_col.split('.', 2).first
    ids.each_slice(500).sum do |slice|
      conn.update("UPDATE #{conn.quote_table_name(table)} SET deleted_at = NULL WHERE deleted_at IS NOT NULL AND id IN (#{slice.map(&:to_i).join(',')})").to_i
    end
  end
end

lib[:take_snapshot] = lambda do |targets, label, cascade_types = []|
  # 'FormSet' targets only record which forms a model type has (see model_forms)
  form_sets = targets.select { |t| t['table'] == 'FormSet' }
  records = (targets - form_sets).map do |t|
    rec = lib[:snapshot_find].call(t)
    entry = t.merge('id' => rec&.id)
    if rec
      cols = t['secret'] ? [] : (t['only_cols'] || snapshot_cols[t['table']])
      entry['cols'] = cols.each_with_object({}) { |c, h| h[c] = rec[c] }
      if rec.has_attribute?(:deleted_at) && rec.deleted_at.present?
        entry['deleted'] = true
        entry['deleted_at'] = rec.deleted_at.utc.iso8601
      end
      entry['links'] = lib[:event_links].call(rec) if t['table'] == 'MachineEvent'
    end
    entry
  end
  snap = { 'format' => 1, 'label' => label, 'taken_at' => Time.now.utc.iso8601, 'records' => records }
  # Which forms each PDC model had, so a restore can remove forms created since
  models = targets.select { |t| %w[MachineModelType FormSet].include?(t['table']) }.map { |t| t['find']['model_type'] }.uniq
  snap['model_forms'] = models.each_with_object({}) do |mt, h|
    h[mt] = Stencil.where(model_type: mt, deleted_at: nil).to_a.select { |f| lib[:form_types].call(f).include?('form') }.map(&:id)
  end
  snap['cascade'] = lib[:capture_cascade].call(cascade_types) unless cascade_types.empty?
  snap
end

lib[:snapshot_doc_type_name] = 'Snapshot'

# The deploy model's Snapshot document type, created if it's missing.
lib[:snapshot_doc_type] = lambda do |deploy_model|
  mt = deploy_model.class.name
  name = lib[:snapshot_doc_type_name]
  dt = ModelDocumentType.where(model_type: mt, name: name).where('retired IS NULL OR retired = ?', false).order(:id).first
  dt || ModelDocumentType.create!(model_type: mt, name: name, doc_label: 'default', permission_name: 'read_only',
                                  model_theme_id: ModelTheme.where(model_type: mt, deleted_at: nil).order(:id).first&.id)
end

# Text documents are shown as HTML in Fluxx, and snapshots hold form HTML and
# scripts, so the JSON is stored HTML-escaped inside <pre>: it displays as
# readable JSON and nothing in it runs.
lib[:snapshot_text] = lambda { |snap| "<pre>#{CGI.escapeHTML(JSON.pretty_generate(snap))}</pre>" }
lib[:snapshot_parse] = lambda do |text|
  JSON.parse(CGI.unescapeHTML(text.to_s.sub(/\A\s*<pre>/, '').sub(%r{</pre>\s*\z}, '')))
end

# Saves a snapshot as a new document, checks it reads back identical, and
# returns the pointer to store in previous_ / current_configuration.
lib[:save_snapshot] = lambda do |deploy_model, snap, repo_ref|
  recs = snap['records']
  meta = { 'label' => snap['label'], 'taken_at' => snap['taken_at'],
           'components' => recs.count { |r| r['id'] && !r['deleted'] && r['table'] != 'Stencil' },
           'stencils' => recs.count { |r| r['table'] == 'Stencil' && r['id'] } }
  name = "PDC snapshot #{Time.parse(snap['taken_at']).utc.strftime('%Y-%m-%d %H:%M:%S')} UTC #{snap['label']} (#{repo_ref}).json"
  dt = lib[:snapshot_doc_type].call(deploy_model)
  text = lib[:snapshot_text].call(snap)
  doc = ModelDocument.create!(documentable: deploy_model, model_document_type_id: dt.id, document_type: 'text',
                              document_text: text, document_file_name: name, doc_label: dt.doc_label || 'default',
                              document_description: "#{meta['components']} components, #{meta['stencils']} forms")
  back = ModelDocument.find(doc.id).document_text.to_s
  unless back == text && lib[:snapshot_parse].call(back) == snap
    doc.destroy rescue nil
    raise "snapshot document #{doc.id} did not read back intact, so nothing was changed"
  end
  JSON.generate('meta' => meta.merge('document_id' => doc.id, 'document_name' => name, 'kb' => (text.bytesize / 1024.0).round),
                'document_id' => doc.id)
end

# The snapshot a pointer field refers to, or nil if there is none.
lib[:read_snapshot] = lambda do |deploy_model, field|
  next nil unless deploy_model.respond_to?(field)
  raw = deploy_model.public_send(field).to_s
  next nil if raw.strip.empty?
  id = (JSON.parse(raw)['document_id'] rescue nil)
  raise "#{field} doesn't point to a snapshot document" if id.nil?
  doc = ModelDocument.where(id: id).first
  raise "snapshot document #{id} (from #{field}) no longer exists" if doc.nil? || (doc.respond_to?(:deleted_at) && doc.deleted_at.present?)
  lib[:snapshot_parse].call(doc.document_text)
end

# Raises unless this user can save custom Ruby (tested inside a savepoint
# that is always rolled back).
lib[:require_ruby_access] = lambda do |deploy_model|
  denied =
    begin
      ActiveRecord::Base.transaction(requires_new: true) do
        ModelMethod.create!(model_type: deploy_model.class.name, method_type: 'method', name: 'PDC Permission Probe', unsafe_dyn_method: "'ok'")
        raise ActiveRecord::Rollback
      end
      nil
    rescue => e
      "#{e.class}: #{e.message}"
    end
  raise "This user cannot save custom Ruby in Fluxx, which the PDC installer needs (#{denied})" if denied
end

# The frame every changing action runs in:
#   1. stop unless this user can save custom Ruby
#   2. snapshot everything in targets to a document, and stop unless it reads
#      back intact (nothing has changed yet)
#   3. work.call(log) does the changes, adding { status => [keys] } to log;
#      it may return extra fields for the results record
#   4. snapshot again; point previous_ / current_configuration at the two
#      documents, and store the results record
# Inside a button hook the record is saved by Fluxx afterwards; a pasted
# test script passes save_now = true.
# cascade_types: model types whose related configuration rows the snapshot also
# lists (see capture_cascade), for actions that soft-delete models
lib[:run_with_snapshots] = lambda do |deploy_model, title, results_field, targets, save_now, work, cascade_types = []|
  log = Hash.new { |h, k| h[k] = [] }
  extra = {}
  before_value = nil
  begin
    %w[previous_configuration current_configuration].each do |f|
      raise "This deploy model has no #{f} field; click Update Installer first" unless deploy_model.respond_to?("#{f}=")
    end
    lib[:require_ruby_access].call(deploy_model)
    ref = lib[:repo_ref].call(deploy_model)
    before_value = lib[:save_snapshot].call(deploy_model, lib[:take_snapshot].call(targets, "before #{title}", cascade_types), ref)
    extra = work.call(log) || {}
  rescue => e
    at = Array(e.backtrace).find { |b| b.include?('eval') } || Array(e.backtrace).first
    extra['error'] = "#{e.class}: #{e.message} (at #{at})#{before_value ? ' (some changes may have been made; Restore Previous undoes them)' : ''}"
  end
  # Nothing changed: drop the two snapshot documents and keep the pointers, so
  # Restore Previous still goes back past the last real change.
  # (An error may have struck after a write and before its log line, so a
  # failed run always keeps its snapshots.)
  changed = log.any? { |status, keys| keys.any? && results_tone.call(status) == 'done' }
  if before_value && !changed && !extra['error']
    ModelDocument.where(id: JSON.parse(before_value)['document_id']).destroy_all rescue nil
    before_value = nil
    extra['mode'] = [extra['mode'], 'nothing changed'].compact.join('; ') unless extra['error']
  end
  if before_value
    deploy_model.previous_configuration = before_value
    deploy_model.current_configuration =
      begin
        lib[:save_snapshot].call(deploy_model, lib[:take_snapshot].call(targets, "after #{title}"), lib[:repo_ref].call(deploy_model))
      rescue => e
        extra['error'] = [extra['error'], "the after-snapshot could not be saved: #{e.class}: #{e.message}"].compact.join('; ')
        nil
      end
  end
  mode = extra.delete('mode') || (extra['error'] ? 'failed' : 'done')
  record = lib[:results_record].call(title, mode, lib[:log_entries].call(log), extra)
  saved = lib[:store_results].call(deploy_model, results_field, record, false)
  deploy_model.save! if save_now
  "PDC #{title} (#{mode}; #{saved}): " + record['summary'].map { |s| "#{s['label']} #{s['count']}" }.join(', ') +
    (extra['error'] ? " || #{extra['error']}" : '')
end


lib
