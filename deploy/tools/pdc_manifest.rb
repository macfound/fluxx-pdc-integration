#!/usr/bin/env ruby
# Builds and checks deploy/pdc-manifest.json. Plain Ruby, no gems.
#
#   ruby deploy/tools/pdc_manifest.rb unpack EXPORT.json [--take ID[@STENCIL_ID] ...]
#       Writes the bodies from a PDC_Export_Components export into the repo,
#       then regenerates deploy/pdc-manifest.json from the repo files.
#       Stencil-element files normally win over Fluxx; --take replaces one with
#       Fluxx's copy (marker added). Add @STENCIL_ID when Fluxx has different
#       copies in different stencils.
#   ruby deploy/tools/pdc_manifest.rb rehash
#       Recomputes every hash in the manifest from the repo files (run after
#       editing a body by hand), and rewrites deploy/pdc-install-bundle.json.
#   ruby deploy/tools/pdc_manifest.rb check
#       Fails if any manifest hash is stale, a referenced file is missing,
#       a data-explorer file doesn't match its own marker/fingerprints, or the
#       install bundle is out of date.
#
# The normalize/hash rules MUST stay identical to deploy/installer/PDC
# Installer Lib.rb, or every body will report DIFFERS in Fluxx.

require 'json'
require 'digest'
require 'fileutils'
require 'zlib'
require 'base64'
require 'cgi'

ROOT = File.expand_path('../..', __dir__)
SCOPE_PATH = File.join(ROOT, 'deploy/pdc-scope.json')
MANIFEST_PATH = File.join(ROOT, 'deploy/pdc-manifest.json')
BUNDLE_PATH = File.join(ROOT, 'deploy/pdc-install-bundle.json')

# Body fields per manifest section. Stencil "json" is hashed structurally.
BODY_FIELDS = {
  'methods' => %w[body],
  'themes' => %w[before_new after_create],
  'states' => %w[before_validation_enter after_enter],
  'events' => %w[guard],
  'stencils' => %w[json],
  'shared_slices' => %w[body]
}.freeze
SECTIONS = %w[models permissions attributes methods themes states workflows events stencils shared_slices stencil_elements].freeze

def normalize(text)
  return nil if text.nil?
  out = text.to_s.gsub("\r\n", "\n").split("\n").map(&:rstrip).join("\n").strip
  out.empty? ? nil : out
end

def sha(text)
  norm = normalize(text)
  norm && Digest::SHA256.hexdigest(norm)
end

# A stencil element's text the way Fluxx's editor leaves it: entities decoded,
# the marker line dropped, "/>" and " >" written as ">", whitespace runs collapsed.
# Lets Install recognize an unmarked copy of PDC's own text.
def shape_sha(text)
  t = CGI.unescapeHTML(text.to_s).sub(Regexp.new("^[^\\n]*#{scope['markers']['element_regex']}[^\\n]*\\n?"), '')
  # Fluxx writes some named entities as the characters (&hellip; as the
  # ellipsis), and CGI only decodes the basic ones, so both are left out
  t = t.gsub(/&[a-zA-Z][a-zA-Z0-9]*;/, '').gsub(/[^\x00-\x7F]/, '')
  t = t.gsub(%r{\s*/?>}, '>').gsub(/\s+/, ' ').strip
  t.empty? ? nil : Digest::SHA256.hexdigest(t)
end

def canon(obj, volatile, masked = [])
  case obj
  when Hash
    obj.keys.sort.each_with_object({}) do |k, h|
      next if volatile.include?(k)
      h[k] = masked.include?(k) && !obj[k].nil? ? '<profile>' : canon(obj[k], volatile, masked)
    end
  when Array
    obj.map { |v| canon(v, volatile, masked) }
  else
    obj
  end
end

# Show/hide conditions inside a stencil's "advanced_query" strings can name a
# dropdown option by id ([attribute, op, option_id]); ids differ per instance.
# rewrite_conditions passes each such value through fn.call(attribute, value)
# and keeps the string untouched when nothing changes.
def rewrite_conditions(obj, &fn)
  case obj
  when Hash
    obj.each_with_object({}) do |(k, v), h|
      h[k] = k == 'advanced_query' && v.is_a?(String) ? rewrite_query(v, &fn) : rewrite_conditions(v, &fn)
    end
  when Array then obj.map { |v| rewrite_conditions(v, &fn) }
  else obj
  end
end

def rewrite_query(str, &fn)
  q = (JSON.parse(str) rescue nil)
  return str unless q.is_a?(Hash)
  changed = false
  walk = lambda do |node|
    next node unless node.is_a?(Array)
    if node.size == 3 && node.all? { |x| x.is_a?(String) }
      v = fn.call(node[0], node[2])
      next node if v == node[2]
      changed = true
      next [node[0], node[1], v]
    end
    node.map { |x| walk.call(x) }
  end
  out = q.merge('conditions' => walk.call(q['conditions']))
  changed ? JSON.generate(out) : str
end

# Option ids in model-form conditions, as names ("option:<value>"), per model type
def option_names(model_type)
  (scope['stencil_option_ids'] || {}).each_with_object({}) do |(key, ids), h|
    mt, attr = key.split('.', 2)
    h[attr] = ids if mt == model_type
  end
end

def stencil_sha(raw, volatile, masked = [], model_type = nil)
  return nil if raw.nil? || raw.strip.empty?
  doc = JSON.parse(raw)
  names = model_type ? option_names(model_type) : {}
  doc = rewrite_conditions(doc) { |attr, v| names[attr] && names[attr][v] ? "option:#{names[attr][v]}" : v } unless names.empty?
  Digest::SHA256.hexdigest(JSON.generate(canon(doc, volatile, masked), ascii_only: true))
end

def scope
  @scope ||= JSON.parse(File.read(SCOPE_PATH, encoding: "UTF-8"))
end

def safe_name(name)
  name.to_s.gsub(%r{[/\\:*?"<>|]}, '-').strip
end

def folder_for(model_type)
  owned = scope['owned_model_types'][model_type]
  return owned['folder'] if owned
  return scope['grant_request']['folder'] if model_type == scope['grant_request']['model_type']
  raise "No repo folder for model type #{model_type}"
end

# Repo path for one body field of one manifest entry.
def body_path(section, entry, field)
  case section
  when 'methods'
    "#{folder_for(entry['model_type'])}/#{entry['name']}.rb"
  when 'themes'
    "#{folder_for(entry['model_type'])}/#{field == 'before_new' ? 'Before New' : 'After Create'}.rb"
  when 'states'
    "#{folder_for(entry['model_type'])}/states/#{safe_name(entry['name'])}.#{field}.rb"
  when 'events'
    "#{folder_for(entry['model_type'])}/events/#{safe_name(entry['button_name'])}.#{field}.rb"
  when 'stencils'
    "#{folder_for(entry['model_type'])}/stencils/form.json"
  when 'shared_slices'
    hook = scope['grant_request']['shared_state_hooks'].find { |h| h['state'] == entry['state'] && h['field'] == entry['field'] }
    raise "No repo path for shared hook #{entry['key']}" unless hook
    hook['path']
  end
end

def read_repo(path)
  full = File.join(ROOT, path)
  File.exist?(full) ? File.read(full, encoding: "UTF-8") : nil
end

# The owned model type whose folder holds path, e.g. pdc-map/pdc-consent/... -> MacModelTypeDynPdcConsent
def model_type_for_path(path)
  scope['owned_model_types'].find { |_, v| path.start_with?("#{v['folder']}/") }&.first
end

def hash_for(section, field, path)
  text = read_repo(path)
  return nil if text.nil?
  return sha(text) unless section == 'stencils' && field == 'json'
  stencil_sha(text, scope['stencil_volatile_keys'] || [], scope['stencil_profile_keys'] || [], model_type_for_path(path))
end

# Recomputes every *_sha256 from the *_path it sits next to. Returns
# a list of problems (missing files).
def rehash!(manifest)
  problems = []
  (manifest.keys & SECTIONS).each do |section|
    manifest[section].each do |entry|
      if section == 'stencil_elements'
        text = read_repo(entry['path'])
        entry['sha256'] = sha(text)
        # Same content without its marker line, for copies not yet marked in Fluxx.
        entry['unmarked_sha256'] = text && sha(text.sub(Regexp.new("^[^\\n]*#{scope['markers']['element_regex']}[^\\n]*\\n?"), ''))
        # Shapes of this and every earlier release, so Install can tell PDC's
        # own unmarked copies from admin edits.
        # Without git, the earlier releases recorded last time are kept.
        entry['shape_sha256'] = text && shape_sha(text)
        past = past_texts(entry['path'])
        entry['past_shape_sha256'] = (past.map { |t| shape_sha(t) }.compact.uniq - [entry['shape_sha256']]).sort if past
        problems << "#{entry['path']} is missing" if entry['sha256'].nil?
        next
      end
      entry.keys.grep(/_path\z/).each do |path_key|
        field = path_key.sub(/_path\z/, '')
        entry["#{field}_sha256"] = hash_for(section, field, entry[path_key])
        problems << "#{entry[path_key]} is missing" if entry["#{field}_sha256"].nil?
      end
    end
  end
  problems
end

# Every committed version of a repo file, oldest renames included. nil when
# git isn't available.
def past_texts(path)
  log = IO.popen(['git', '-C', ROOT, 'log', '--follow', '--format=%H', '--name-only', '--', path], err: File::NULL, &:read)
  return nil unless $?.success?
  log.split("\n").reject(&:empty?).each_slice(2).map do |commit, at|
    IO.popen(['git', '-C', ROOT, 'show', "#{commit}:#{at}"], err: File::NULL, &:read).force_encoding('UTF-8')
  end
end

def write_repo(path, text)
  full = File.join(ROOT, path)
  FileUtils.mkdir_p(File.dirname(full))
  File.write(full, text.end_with?("\n") ? text : "#{text}\n")
end

# Accepts the packed "PDCEXPORT1:<base64 deflate>" line (tolerating console
# noise around it, like quotes or `result = `) or plain JSON.
def read_export(path)
  raw = File.read(path, encoding: 'UTF-8')
  packed = raw[/PDCEXPORT1:([A-Za-z0-9+\/=\s]+)/, 1]
  return JSON.parse(raw) unless packed
  JSON.parse(Zlib::Inflate.inflate(Base64.decode64(packed.gsub(/\s+/, ''))).force_encoding('UTF-8'))
end

# Fluxx's copy of one element as the new repo text, marker line first.
def taken_element_text(live_elements, spec, stencil_id, marker_re)
  locs = Array((live_elements[spec['id']] || {})['locations'])
  locs = locs.select { |l| l['stencil_id'].to_s == stencil_id.to_s } if stencil_id
  texts = locs.map { |l| l['text'] }.compact.uniq
  abort "--take #{spec['id']}: not found in the export" if texts.empty?
  if texts.size > 1
    abort "--take #{spec['id']}: Fluxx has #{texts.size} different copies; pick one with " +
          locs.map { |l| "#{spec['id']}@#{l['stencil_id']} (#{l['stencil_name'].to_s.strip})" }.uniq.join(' or ')
  end
  text = texts.first
  # A top-level marker comment would show as "undefined" (see the scope's _element_regex)
  abort "--take #{spec['id']}: Fluxx's copy has no PDC:ELEMENT marker; add one inside its first element first" unless text =~ marker_re
  text
end

def unpack(export_path, takes = [])
  export = read_export(export_path)
  abort "Export reports an error: #{export['error']}" if export['error']
  live = export['live'] or abort 'Not a PDC_Export_Components export (no "live" key)'
  # Exports from before permissions were collected carry them in extras.
  if live['permissions'].nil? && (rules = (export['extras'] || {})['user_profile_rules_for_pdc']).is_a?(Array)
    live['permissions'] = rules.group_by { |r| [r['model_type'], r['permission_name']] }.map do |(mt, perm), rs|
      { 'key' => "#{mt}:#{perm}", 'model_type' => mt, 'permission_name' => perm,
        'allowed' => rs.any? { |r| r['allowed'] == true || r['allowed'] == 1 } }
    end
  end

  manifest = {
    '_comment' => 'Generated by deploy/tools/pdc_manifest.rb from a PDC_Export_Components export. Do not edit by hand; edit the repo files and run `rehash`.',
    'format' => 1,
    'source' => { 'exported_at' => export['exported_at'], 'deploy_model' => export['deploy_model'], 'ref' => export['ref'] },
    'scope' => scope
  }
  cross_check = []

  SECTIONS.each do |section|
    if section == 'stencil_elements'
      # Repo files are authoritative for elements (they carry the markers).
      # An element with no repo file yet is seeded from the export, marker added.
      marker_re = Regexp.new(scope['markers']['element_regex'])
      live_elements = Array(live['stencil_elements']).map { |e| [e['id'], e] }.to_h
      takes.each do |take|
        id, stencil_id = take.split('@', 2)
        spec = scope['stencil_elements'].find { |e| e['id'] == id } or abort "--take #{id}: unknown element id"
        write_repo(spec['path'], taken_element_text(live_elements, spec, stencil_id, marker_re))
        puts "Took #{spec['path']} from Fluxx#{stencil_id ? " (stencil #{stencil_id})" : ''}"
      end
      scope['stencil_elements'].each do |spec|
        next if read_repo(spec['path'])
        texts = Array((live_elements[spec['id']] || {})['locations']).map { |l| l['text'] }.compact.uniq
        next if texts.empty?
        puts "WARNING: #{spec['id']} has #{texts.size} different copies in Fluxx; seeded from the first" if texts.size > 1
        text = texts.first
        puts "WARNING: #{spec['path']} has no PDC:ELEMENT marker; add one inside its first element" unless text =~ marker_re
        write_repo(spec['path'], text)
        puts "Seeded #{spec['path']} from Fluxx"
      end
      manifest[section] = scope['stencil_elements'].map do |spec|
        { 'key' => spec['id'], 'id' => spec['id'], 'path' => spec['path'], 'host_model_types' => spec['host_model_types'] }
      end
      next
    end

    manifest[section] = Array(live[section]).sort_by { |e| e['key'] }.map do |live_entry|
      entry = live_entry.reject { |k, _| %w[roles profiles marker_found].include?(k) }
      Array(BODY_FIELDS[section]).each do |field|
        body = entry.delete(field)
        exported_sha = entry["#{field}_sha256"]
        if section == 'methods' && entry['secret']
          next # repo keeps a placeholder; never compared
        end
        if body.nil? && !(section == 'shared_slices' && live_entry['marker_found'] == false)
          next # empty in Fluxx: no file, sha stays null
        end
        path = body_path(section, entry, field)
        entry["#{field}_path"] = path
        # Leave the repo file alone when it already hashes the same (avoids
        # whitespace-only churn).
        if !body.nil? && hash_for(section, field, path) != exported_sha
          write_repo(path, field == 'json' ? JSON.pretty_generate(body) : body)
          local_sha = hash_for(section, field, path)
          cross_check << "#{section} #{entry['key']} #{field}: Fluxx #{exported_sha} vs local #{local_sha}" if local_sha != exported_sha
        end
      end
      entry
    end
  end

  # One element per required native field, as it sits on a working form, so a
  # later install can add it to a stencil that lacks it.
  templates = {}
  Array(live['stencil_fields']).each { |f| templates[f['attribute']] ||= f['element'] if f['element'] }
  manifest['stencil_field_templates'] = templates unless templates.empty?

  problems = rehash!(manifest)
  File.write(MANIFEST_PATH, JSON.pretty_generate(manifest) + "\n")
  write_bundle(manifest)
  puts "Wrote #{MANIFEST_PATH} and #{BUNDLE_PATH}"
  SECTIONS.each { |s| puts format('  %-17s %d', s, manifest[s].size) }
  unless cross_check.empty?
    puts "\nHASH CROSS-CHECK FAILED: Fluxx and this tool hash the same text differently."
    puts '  Fix the normalize/canon rules before trusting validation:'
    cross_check.each { |c| puts "  #{c}" }
  end
  problems.each { |p| puts "WARNING: #{p}" }
  puts 'Review `git status` / `git diff`: bodies from Fluxx overwrote repo files where they differed.'
end

def fingerprint_problems
  marker_re = Regexp.new(scope['markers']['element_regex'])
  specs = scope['stencil_elements']
  specs.flat_map do |spec|
    text = read_repo(spec['path'])
    next ["#{spec['path']} is missing"] if text.nil?
    out = []
    m = text.match(marker_re)
    out << "#{spec['path']}: marker id is #{m ? m[1].inspect : 'absent'}, expected #{spec['id'].inspect}" unless m && m[1] == spec['id']
    matches = specs.select do |s|
      s['include'].all? { |t| text.include?(t) } && s['exclude'].none? { |t| text.include?(t) }
    end.map { |s| s['id'] }
    out << "#{spec['path']}: fingerprints match #{matches.inspect}, expected only #{spec['id'].inspect}" unless matches == [spec['id']]
    out
  end
end

# Everything PDC Install / Uninstall need in one file, so Fluxx makes a single
# fetch: the manifest entries with their bodies inlined. Secret methods are
# listed by name only (Install never writes them; Uninstall soft-deletes them).
def build_bundle(manifest)
  body = lambda { |path| path && read_repo(path) }
  {
    '_comment' => 'Generated by deploy/tools/pdc_manifest.rb rehash from pdc-manifest.json and the repo files. Do not edit.',
    'source' => manifest['source'],
    'scope' => manifest['scope'],
    'models' => manifest['models'].map { |m| m.slice('key', 'model_type', 'name', 'show_in_plus_menu') },
    'workflows' => manifest['workflows'].map { |w| w.slice('key', 'model_type', 'theme', 'name') },
    'permissions' => manifest['permissions'].map { |x| x.slice('key', 'model_type', 'permission_name', 'allowed') },
    'stencils' => manifest['stencils'].map { |st| st.slice('key', 'model_type', 'name').merge('json' => JSON.parse(read_repo(st['json_path']))) },
    'attributes' => manifest['attributes'].map do |a|
      a.slice('key', 'model_type', 'name', 'description', 'attribute_type', 'multi_allowed', 'value_model_type', 'options')
    end,
    'methods' => manifest['methods'].map do |m|
      e = m.slice('key', 'model_type', 'name', 'method_type')
      # Secret methods carry only the repo placeholder ("Not Configured"), which
      # Install uses to create them when missing
      m['secret'] ? e.merge('secret' => true, 'placeholder' => read_repo(body_path('methods', m, 'body'))) : e.merge('body' => body.call(m['body_path']))
    end,
    'themes' => manifest['themes'].map do |t|
      t.slice('key', 'model_type', 'name', 'label', 'external_access_enabled', 'limit_by_user_profile_flag',
              'hide_from_theme_switching', 'request_may_be_grantee_user_only').merge('before_new' => body.call(t['before_new_path']), 'after_create' => body.call(t['after_create_path']))
    end,
    'states' => manifest['states'].map do |st|
      st.slice('key', 'model_type', 'name', 'description', 'state_type', 'state_order', 'allowed_roles')
        .merge('before_validation_enter' => body.call(st['before_validation_enter_path']), 'after_enter' => body.call(st['after_enter_path']))
    end,
    'events' => manifest['events'].map do |e|
      e.slice('key', 'model_type', 'theme', 'button_name', 'name', 'to_state', 'from_states', 'is_validation_suppressed',
              'guard_strategy', 'filter').merge('guard' => body.call(e['guard_path']))
    end,
    'shared_slices' => manifest['shared_slices'].map { |x| x.slice('key', 'model_type', 'state', 'field').merge('body' => body.call(x['body_path'])) },
    'stencil_elements' => manifest['stencil_elements'].map do |el|
      spec = scope['stencil_elements'].find { |sp| sp['id'] == el['id'] } || {}
      el.slice('key', 'id', 'host_model_types', 'sha256', 'unmarked_sha256', 'shape_sha256', 'past_shape_sha256').merge('text' => read_repo(spec['path'] || el['path']).to_s.strip)
    end
  }
end

def write_bundle(manifest)
  File.write(BUNDLE_PATH, JSON.pretty_generate(build_bundle(manifest)) + "\n")
end

def check
  problems = fingerprint_problems
  if File.exist?(MANIFEST_PATH)
    manifest = JSON.parse(File.read(MANIFEST_PATH, encoding: "UTF-8"))
    fresh = JSON.parse(JSON.generate(manifest))
    problems.concat(rehash!(fresh))
    problems << 'manifest scope differs from deploy/pdc-scope.json (run rehash)' if manifest['scope'] != scope
    (manifest.keys & SECTIONS).each do |section|
      manifest[section].each_with_index do |entry, i|
        entry.each do |k, v|
          next unless k.end_with?('sha256') && fresh[section][i][k] != v
          problems << "stale hash: #{section} #{entry['key']} #{k} (run rehash)"
        end
      end
    end
    unless File.exist?(BUNDLE_PATH) && JSON.parse(File.read(BUNDLE_PATH, encoding: 'UTF-8')) == JSON.parse(JSON.generate(build_bundle(manifest)))
      problems << 'deploy/pdc-install-bundle.json is out of date (run rehash)'
    end
  else
    puts "No #{MANIFEST_PATH} yet (run unpack on an export); checked fingerprints only."
  end
  if problems.empty?
    puts 'OK'
  else
    problems.each { |p| puts p }
    exit 1
  end
end


case ARGV[0]
when 'unpack'
  abort 'usage: pdc_manifest.rb unpack EXPORT.json [--take ID[@STENCIL_ID] ...]' unless ARGV[1]
  takes = ARGV[2..-1].each_slice(2).map { |flag, val| flag == '--take' && val ? val : abort("unknown option #{flag}") }
  unpack(ARGV[1], takes)
when 'rehash'
  manifest = JSON.parse(File.read(MANIFEST_PATH, encoding: "UTF-8"))
  manifest['scope'] = scope
  problems = rehash!(manifest)
  File.write(MANIFEST_PATH, JSON.pretty_generate(manifest) + "\n")
  write_bundle(manifest)
  problems.each { |p| puts "WARNING: #{p}" }
  puts "Rehashed #{MANIFEST_PATH} and wrote #{BUNDLE_PATH}"
when 'check'
  check
else
  abort File.read(__FILE__).lines.drop(1).take_while { |l| l.start_with?('#') }.join
end
