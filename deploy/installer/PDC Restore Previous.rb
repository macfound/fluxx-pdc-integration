# PDC Restore Previous
#
# The Restore Previous button on the deploy model. Puts every PDC component
# back the way previous_configuration recorded it (the snapshot Install,
# Uninstall or an earlier Restore took before changing anything):
#   - a component that existed then gets its code and settings back, and is
#     un-deleted if it was soft-deleted since (same id, so saved answers and
#     links keep working); one that was hard-deleted is recreated
#   - a component that didn't exist then is soft-deleted
#   - forms that held PDC elements get their saved JSON back
#   - buttons get their target, from-states and roles back
# Anything changed by someone else since the last action (it no longer
# matches current_configuration's snapshot) is left alone and listed.
# Needs no repo access. Restore takes its own snapshot first, so clicking it
# again undoes the restore. Results go to restore_results.

require 'json'
require 'time'

lib = model.dyn_invoke_for(:"PDC Installer Lib") unless defined?(lib) && lib
save_now = defined?(pdc_one_off) && pdc_one_off ? true : false

read_error = nil
previous = begin
  lib[:read_snapshot].call(model, 'previous_configuration')
rescue => e
  read_error = e.message
  nil
end
# The after-snapshot of the last action: anything that differs from it now was
# changed by someone since, and isn't overwritten.
latest_error = nil
latest = begin
  lib[:read_snapshot].call(model, 'current_configuration')
rescue => e
  latest_error = e.message
  nil
end
latest_by_key = latest ? latest['records'].each_with_object({}) { |r, h| h[r['key']] = r } : {}
targets = previous ? previous['records'].map { |r| r.slice('table', 'key', 'find', 'secret', 'cols_only', 'only_cols') } : []
# Keep recording the same form sets, and the forms this restore may remove
# (PDC model forms, "(PDC)" grant copies) by id, so this restore can be undone too
form_types_of = previous ? (previous['model_forms'] || {}).keys : []
targets += form_types_of.map { |mt| { 'table' => 'FormSet', 'key' => "forms #{mt}", 'find' => { 'model_type' => mt } } }
form_types_of.each do |mt|
  dynamic = MachineModelType.where(model_type: mt).exists?
  Stencil.where(model_type: mt, deleted_at: nil).each do |f|
    next unless dynamic || f.name.to_s.strip.end_with?('(PDC)', '(PDC Removed)')
    next if targets.any? { |t| t['table'] == 'Stencil' && t['find'] == { 'id' => f.id } }
    targets << { 'table' => 'Stencil', 'key' => "stencil #{f.id}", 'find' => { 'id' => f.id } }
  end
end

restore = lambda do |log|
  raise(read_error || 'There is no previous configuration to restore yet') if previous.nil?
  now = Time.now
  # Soft-delete where the table supports it; otherwise (e.g. a permission rule
  # Install created) remove the row
  remove = lambda do |rec|
    if rec.has_attribute?(:deleted_at)
      rec.deleted_at = now
      rec.save!
    else
      rec.destroy
    end
  end
  # True when the live record no longer matches the last action's
  # after-snapshot (someone edited it since).
  changed_since = lambda do |r|
    after = latest_by_key[r['key']]
    next false if after.nil?
    live = lib[:snapshot_find].call(r)
    next !after['id'].nil? if live.nil?
    if after['id'].nil?
      # It didn't exist after the last action; a live one was created since
      next !(live.has_attribute?(:deleted_at) && live.deleted_at.present?)
    end
    next true if live.id != after['id']
    live_deleted = live.has_attribute?(:deleted_at) && live.deleted_at.present?
    next true if live_deleted != (after['deleted'] ? true : false)
    next true if (after['cols'] || {}).any? { |c, v| live[c] != v }
    r['table'] == 'MachineEvent' && after['links'] && !lib[:same_links].call(lib[:event_links].call(live), after['links'])
  end
  # Records in dependency order, so fields exist before their options and
  # states before the buttons that point at them. Removals of things that
  # didn't exist before run afterwards in reverse, so options go before their
  # field.
  # Decided before anything changes, so this restore's own changes (a record
  # can appear under more than one key) never count as someone else's
  changed_keys = previous['records'].select { |r| changed_since.call(r) }.map { |r| r['key'] }
  removals = previous['records'].select { |r| r['id'].nil? && r['table'] != 'Stencil' && !r['cols_only'] }
  (previous['records'] - removals + removals.reverse).each do |r|
    key = r['key']
    klass = lib[:snapshot_class].call(r['table'])
    cols = r['cols'] || {}
    if changed_keys.include?(key)
      log['review: changed since the last action, left alone'] << key
      next
    end

    if r['table'] == 'Stencil'
      st = lib[:snapshot_find].call(r)
      if r['id'].nil?
        # A form that didn't exist before (a PDC copy): remove it
        if st && st.deleted_at.nil?
          st.deleted_at = now
          st.save!
          log['removed (was not there before)'] << key
        else
          log['ok'] << key
        end
      elsif st.nil?
        log['review: form not found'] << key
      else
        changed = []
        changed << 'json' if st['json'].to_s != cols['json'].to_s
        changed << 'enabled' if cols.key?('enabled') && st.enabled != cols['enabled']
        changed << 'un-deleted' if st.deleted_at.present? && !r['deleted']
        if changed.empty?
          log['ok'] << key
        else
          st.enabled = cols['enabled'] if cols.key?('enabled')
          st.deleted_at = nil if st.deleted_at.present? && !r['deleted']
          changed.include?('json') ? lib[:write_stencil].call(st, cols['json']) : st.save!
          log['restored form'] << "#{key} [#{changed.join(', ')}]"
        end
      end
      next
    end

    if r['cols_only']
      rec = lib[:snapshot_find].call(r, true)
      if rec.nil? || r['id'].nil?
        log['review: not found'] << key
        next
      end
      changed = cols.reject { |c, v| rec[c] == v }.keys
      if changed.empty?
        log['ok'] << key
      else
        changed.each { |c| rec[c] = cols[c] }
        rec.save!
        log['restored'] << "#{key} [#{changed.join(', ')}]"
      end
      next
    end

    live = lib[:snapshot_find].call(r, true)
    if r['id'].nil?
      # Didn't exist before
      if live
        remove.call(live)
        log['removed (was not there before)'] << key
      else
        log['ok'] << key
      end
      next
    end

    rec = klass.find_by(id: r['id'])
    changed = []
    if rec.nil?
      if r['deleted']
        log['ok'] << key
        next
      end
      if r['secret']
        log['review: secret method was hard-deleted; re-enter it by hand'] << key
        next
      end
      scope = lib[:snapshot_scope].call(r)
      if scope.nil?
        log['review: could not recreate, its field or workflow is missing'] << key
        next
      end
      attrs = scope.where_values_hash.merge(cols)
      if r['table'] == 'MachineEvent' && r['links']
        l = r['links']
        attrs['to_state_id'] = MachineState.where(id: l['to_state_id']).exists? ? l['to_state_id'] :
                                 MachineState.where(model_type: r['find']['model_type'], name: l['to_state'], deleted_at: nil).first&.id
      end
      rec = klass.new(attrs)
      if r['table'] == 'MachineEvent'
        # Fluxx won't save a button without a role; links are put right below
        lib[:save_event].call(rec, Array((r['links'] || {})['roles']), [])
      else
        rec.save!
      end
      changed = ['recreated']
      log['recreated'] << key
    else
      if live && live.id != rec.id && !r['deleted']
        remove.call(live)
        log['removed (duplicate of the restored one)'] << "#{key} (id #{live.id})"
      end
      changed = cols.reject { |c, v| rec[c] == v }.keys
      was_deleted = rec.has_attribute?(:deleted_at) && rec.deleted_at.present?
      changed << (r['deleted'] ? 'deleted' : 'un-deleted') if was_deleted != (r['deleted'] ? true : false)
      if changed.empty?
        log['ok'] << key unless r['table'] == 'MachineEvent'
      else
        cols.each { |c, v| rec[c] = v }
        rec.deleted_at = r['deleted'] ? (rec.deleted_at || Time.parse(r['deleted_at'])) : nil if rec.has_attribute?(:deleted_at)
        rec.save!
        log['restored'] << "#{key} [#{changed.join(', ')}]"
      end
    end

    # Buttons: target, from-states and roles, by state name
    next unless r['table'] == 'MachineEvent' && r['links'] && !r['deleted']
    mt = r['find']['model_type']
    # The same state row if it still exists (deleted or not), else by name
    sid = lambda do |name, id|
      id && MachineState.where(id: id).exists? ? id : MachineState.where(model_type: mt, name: name, deleted_at: nil).first&.id
    end
    links = r['links']
    fixed = []
    to_id = sid.call(links['to_state'], links['to_state_id'])
    if to_id && rec.to_state_id != to_id
      rec.to_state_id = to_id
      rec.save!
      fixed << 'target'
    end
    want_from = lib[:links_from].call(links).map { |name, id| sid.call(name, id) }.compact.uniq.sort
    have_from = MachineEventFromState.where(machine_event_id: rec.id).pluck(:from_state_id).uniq.sort
    if have_from != want_from
      MachineEventFromState.where(machine_event_id: rec.id).destroy_all
      want_from.each { |id| MachineEventFromState.create!(machine_event_id: rec.id, from_state_id: id) }   # Fluxx sets the order
      fixed << 'from-states'
    end
    have_roles = MachineEventRole.where(machine_event_id: rec.id).pluck(:role_id).sort
    if have_roles != links['roles']
      MachineEventRole.where(machine_event_id: rec.id).destroy_all
      links['roles'].each { |rid| MachineEventRole.create!(machine_event_id: rec.id, role_id: rid) }
      fixed << 'roles'
    end
    fixed.empty? ? (log['ok'] << key if changed.empty?) : log['restored'] << "#{key} [#{fixed.join(', ')}]"
  end

  warnings = []
  warnings << "The last action's after-snapshot couldn't be read (#{latest_error}), so changes made since then weren't checked" if latest.nil? && model.respond_to?(:current_configuration) && model.current_configuration.present?
  warnings << "There's no after-snapshot of the last action, so changes made since then weren't checked" if latest.nil? && !(model.respond_to?(:current_configuration) && model.current_configuration.present?)
  # Forms created since: any new form of a PDC model, and the "(PDC)" copies
  # of grant forms (a grant form someone made by hand is never touched)
  (previous['model_forms'] || {}).each do |mt, ids|
    dynamic = MachineModelType.where(model_type: mt).exists?
    next if dynamic && !MachineModelType.where(model_type: mt, deleted_at: nil).exists?
    Stencil.where(model_type: mt, deleted_at: nil).where.not(id: ids).each do |f|
      next unless lib[:form_types].call(f).include?('form')
      next if !dynamic && !f.name.to_s.strip.end_with?('(PDC)', '(PDC Removed)')
      remove.call(f)
      log['removed (was not there before)'] << "form #{mt} #{f.name.to_s.strip} (stencil #{f.id})"
    end
  end
  # Configuration Fluxx soft-deleted along with a model (labels, mappings,
  # fields pointing at it): bring back the rows the snapshot saw live, for
  # models that are back. Records aren't restored here.
  (previous['cascade'] || {}).each do |mt, per|
    next unless MachineModelType.where(model_type: mt, deleted_at: nil).exists?
    n = lib[:restore_cascade].call(per)
    log['restored settings removed with the model'] << "#{mt}: #{n} rows" if n > 0
  end
  { 'mode' => "back to #{previous['label']} (#{previous['taken_at']})", 'warnings' => warnings }
end

# If this restore removes models again, its own snapshot lists their rows too
cascade_types = previous ? previous['records'].select { |r| r['table'] == 'MachineModelType' }.map { |r| r['find']['model_type'] } : []
lib[:run_with_snapshots].call(model, 'Restore Previous', 'restore_results', targets, save_now, restore, cascade_types)
