# PDC_List_Summary
#
# Called from the deploy model's list view (Liquid: model.PDC_List_Summary in
# stencil/List.liquid). What someone looking after the integration wants at a
# glance: which PDC it talks to, which code is installed, whether the last
# Validate found anything, the last change, the credentials and what's
# switched on. Reads only fields on this record and a few config rows; never
# a credential's value, a snapshot's contents or the repo.

require 'json'
require 'time'

lib = (model.dyn_invoke_for(:"PDC Installer Lib") rescue nil)
read = lambda do |field|
  raw = model.respond_to?(field) ? model.public_send(field).to_s : ''
  next nil if raw.strip.empty?
  JSON.parse(raw) rescue { 'error' => 'These results could not be read.' }
end
when_of = lambda do |s|
  t = (Time.parse(s.to_s) rescue nil)
  t ? t.utc.strftime('%Y-%m-%d %H:%M UTC') : s.to_s
end
count_of = lambda { |rec, tones| Array(rec && rec['summary']).select { |x| tones.include?(x['tone']) }.sum { |x| x['count'].to_i } }
selected = lambda { |attr| lib ? (lib[:selected_values].call(model, attr) rescue []) : [] }

out = {}

# Which PDC
env = selected.call(:pdc_environment).first
env_label = lib && env ? lib[:pdc_environments].dig(env, 'label') : nil
out['environment'] = env_label ? { 'label' => env_label, 'tone' => env == 'production' ? 'good' : 'info' } :
                                 { 'label' => 'No environment chosen', 'tone' => 'bad' }

# Which code: the ref the buttons read from, and the commit the installer was last updated to
commit = model.respond_to?(:installer_commit) ? model.installer_commit.to_s.strip : ''
out['version'] = { 'ref' => (model.respond_to?(:repo_ref) ? model.repo_ref.to_s.strip : '').presence || 'main',
                   'commit' => commit.empty? ? nil : commit[0, 7] }

# Last change (Install, Uninstall or Restore Previous)
changes = %w[install_results uninstall_results restore_results].map { |f| read.call(f) }.compact
last = changes.max_by { |r| r['ran_at'].to_s }
if last
  out['last_change'] = { 'title' => last['title'], 'when' => when_of.call(last['ran_at']), 'error' => last['error'],
                         'changed' => count_of.call(last, %w[done]), 'problems' => count_of.call(last, %w[bad]) }
end

# Last Validate, and whether something changed after it
check = read.call('validate_results')
if check
  issues = count_of.call(check, %w[bad])
  stale = last && last['ran_at'].to_s > check['ran_at'].to_s
  out['check'] = { 'when' => when_of.call(check['ran_at']), 'error' => check['error'], 'issues' => issues,
                   'matches' => count_of.call(check, %w[good]), 'stale' => stale ? last['title'] : nil,
                   'issue_labels' => Array(check['summary']).select { |x| x['tone'] == 'bad' }.map { |x| "#{x['label']} #{x['count']}" }.join(', ') }
end

# Credentials: only whether each holds a value, never the value
map_type = 'MacModelTypeDynPdcApplicationForm1'
out['credentials'] = ['Get PDC Client ID', 'Get PDC Client Secret'].map do |name|
  mm = ModelMethod.where(model_type: map_type, name: name, deleted_at: nil).first
  state = mm.nil? ? 'missing' : (mm.unsafe_dyn_method.to_s.include?('Not Configured') ? 'not entered' : 'set')
  { 'label' => name.sub('Get PDC ', ''), 'state' => state, 'tone' => state == 'set' ? 'good' : 'bad' }
end

# What's switched on
klass = map_type.safe_constantize
out['themes'] = selected.call(:grant_request_themes).size
out['active_maps'] = klass ? (klass.where(state: 'active', deleted_at: nil).count rescue nil) : nil

# What Restore Previous would go back to
prev = read.call('previous_configuration')
meta = prev.is_a?(Hash) ? prev['meta'] : nil
out['restore_point'] = meta ? { 'label' => meta['label'], 'when' => when_of.call(meta['taken_at']) } : nil

# Choices that no longer fit (a role, profile or theme deleted from Fluxx)
out['choice_warnings'] = lib ? (lib[:choice_warnings].call(model, nil) rescue []) : []

# One headline: the worst thing first
needs = []
needs << 'untick what was deleted from Fluxx (see Results)' if out['choice_warnings'].any?
needs << 'choose a PDC Environment' if env_label.nil?
needs << 'enter the PDC credentials' if out['credentials'].any? { |c| c['state'] != 'set' }
needs << "#{last['title']} failed" if last && last['error']
needs << 'Validate failed' if check && check['error']
# (a Validate older than the last change says nothing about what's there now)
needs << "Validate found #{out['check']['issues']} to fix" if check && !check['error'] && !out['check']['stale'] && out['check']['issues'] > 0
out['status'] =
  if last.nil? && check.nil? then { 'label' => 'Not installed yet', 'tone' => 'info', 'detail' => 'Click Validate, then Install' }
  elsif needs.any? then { 'label' => 'Needs attention', 'tone' => 'bad', 'detail' => needs.join('; ') }
  elsif check.nil? || out['check']['stale'] then { 'label' => 'Check again', 'tone' => 'info', 'detail' => 'Click Validate to confirm the last change' }
  else { 'label' => 'Healthy', 'tone' => 'good', 'detail' => 'Matches the repo' }
  end

out
