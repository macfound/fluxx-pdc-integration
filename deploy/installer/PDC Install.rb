# PDC Install
#
# The Install button on the deploy model. Brings every PDC component in line
# with deploy/pdc-install-bundle.json at this record's repo_url / repo_ref:
# installs what's missing, restores what was soft-deleted (keeping its id, so
# saved answers and buttons pointing at it keep working) and overwrites
# anything PDC owns that differs. That makes it both the installer and the
# updater: point repo_ref at another release and click Install.
#
# Never removes anything. Methods, states or buttons it doesn't recognize are
# left alone: whoever built them owns them. If a PDC model still can't be set
# up, nothing outside the PDC models is touched (GrantRequest's PDC hooks need
# all of them).
#
#   models    the three PDC models: kept, brought back if soft-deleted, or
#             created with their exact names; then their themes (label,
#             settings, Before New / After Create code), workflows and forms
#             (from the repo, restricted to the PDC Staff Profile where the
#             repo copy is restricted), and the Consent permissions for the
#             PDC Grantee Profile
#   fields    restore/create fields and static dropdown options; a field
#             whose type or settings differ is only reported (changing a field
#             under existing data is unsafe)
#   methods   restore/create/overwrite (secret methods are never written;
#             Get PDC Base URL is written for the PDC Environment chosen
#             here, and left alone while none is chosen)
#   states    restore/create/overwrite settings and hooks
#   buttons   restore/create/overwrite target, from-states, guard, filter;
#             a button with no role gets the PDC Event Role chosen here (else
#             the role the workflow's other buttons use); with neither, a
#             missing button isn't created
#   granted   the ###PDC_CODE### block in GrantRequest's granted hook
#             (added at the top of the hook if it isn't there)
#   elements  the text, settings and views (edit-only interactive
#             component, detail-only read-only one) of PDC stencil elements
#             already on a form; elements a chosen form lacks (Grant Request Themes, Grant
#             Request Read-only Themes, and the PDC Grantee Profile's dashboard page) are added
#             in a PDC group at the bottom, with the native fields they need,
#             for the admin to move. A grant form with no PDC elements yet is
#             copied as "<name> (PDC)" first: the copy gets them and is
#             switched on, the original is switched off and kept as the
#             rollback. Every active form of a chosen theme is handled.
#
# Validate shows what Install will change. Before changing anything, the
# whole PDC configuration is saved to previous_configuration; Restore
# Previous puts it back. Results go to install_results.

require 'json'
require 'time'
require 'cgi'
require 'securerandom'

lib = model.dyn_invoke_for(:"PDC Installer Lib") unless defined?(lib) && lib
# A pasted test script embeds the bundle and sets pdc_one_off.
bundle = (defined?(pdc_bundle) && pdc_bundle) || lib[:fetch_repo_json].call(model, 'deploy/pdc-install-bundle.json')
# Get PDC Base URL gets the URL of the PDC Environment chosen on this record
lib[:apply_environment].call(bundle, model)
save_now = defined?(pdc_one_off) && pdc_one_off ? true : false

plan = nil   # set below, before the run
install = lambda do |log|
  scope = bundle['scope']
  markers = scope['markers']
  required_config = scope['element_required_config'] || {}

  # Columns whose value differs from what's wanted. Code compares normalized
  # text, so whitespace-only drift doesn't count.
  diffs = lambda do |rec, desired|
    desired.select do |col, val|
      col.start_with?('unsafe_') ? lib[:sha].call(rec[col]) != lib[:sha].call(val) : rec[col] != val
    end.keys
  end
  reconcile = lambda do |key, rec, desired, extra_changes = [], apply_extra = nil|
    changed = diffs.call(rec, desired)
    if changed.empty? && extra_changes.empty?
      log['ok'] << key
      next
    end
    changed.each { |c| rec[c] = desired[c] }
    rec.save! unless changed.empty?
    apply_extra.call if apply_extra
    log['overwrote'] << "#{key} [#{(changed + extra_changes).join(', ')}]"
  end
  # Live record, else bring back the latest soft-deleted one, else a new one.
  revive = lambda do |rel, attrs|
    gone = rel.where.not(deleted_at: nil).order(deleted_at: :desc).first
    rec = gone || rel.klass.new(attrs)
    rec.deleted_at = nil if gone
    [rec, gone ? 'restored' : 'created']
  end

  # The PDC models, with their themes, workflows, forms and permissions. Each
  # is kept if it exists, brought back if it was soft-deleted (same id), or
  # created. (Deleting a model in Fluxx soft-deletes all its configuration;
  # un-deleting it only brings back its forms, so the rest is revived here.)
  owned = scope['owned_model_types'].keys
  live_or_gone = lambda do |rel|
    rel.where(deleted_at: nil).first || rel.where.not(deleted_at: nil).order(deleted_at: :desc).first
  end
  bundle['models'].each do |m|
    rec = live_or_gone.call(MachineModelType.where(model_type: m['model_type']))
    want = { 'name' => m['name'], 'show_in_plus_menu' => m['show_in_plus_menu'] }
    if rec.nil?
      rec = MachineModelType.new(want.merge('model_type' => m['model_type']))
      rec.create_first_theme = true if rec.respond_to?(:create_first_theme=)   # Fluxx adds the theme and its default form
      rec.save!
      log['created model'] << m['key']
    elsif rec.deleted_at.present?
      # Bringing a model back makes Fluxx un-delete every form it ever had;
      # forms that were deleted stay deleted (the form step below makes a new one)
      gone_forms = Stencil.where(model_type: m['model_type']).where.not(deleted_at: nil).pluck(:id)
      rec.deleted_at = nil
      want.each { |c, v| rec[c] = v }
      rec.save!
      Stencil.where(id: gone_forms, deleted_at: nil).each do |f|
        f.deleted_at = Time.now
        f.save!
      end
      log['restored model'] << m['key']
    else
      reconcile.call("model #{m['key']}", rec, want)
    end
  end
  theme_flags = %w[external_access_enabled limit_by_user_profile_flag hide_from_theme_switching request_may_be_grantee_user_only]
  bundle['themes'].each do |t|
    want = { 'label' => t['label'], 'unsafe_before_new_block' => t['before_new'], 'unsafe_after_create_block' => t['after_create'] }
    rec = live_or_gone.call(ModelTheme.where(model_type: t['model_type'], name: t['name']))
    if rec.nil?
      rec = ModelTheme.new(model_type: t['model_type'], name: t['name'])
      rec.stencil_name = 'default' if rec.respond_to?(:stencil_name=)
      how = 'created theme'
    elsif rec.deleted_at.present?
      rec.deleted_at = nil
      how = 'restored theme'
    end
    if how
      want.each { |c, v| rec[c] = v }
      theme_flags.each { |c| rec[c] = t[c] if rec.has_attribute?(c) && !t[c].nil? }
      rec.save!
      log[how] << t['key']
    else
      flags = theme_flags.select { |c| rec.has_attribute?(c) && !t[c].nil? }.each_with_object({}) { |c, h| h[c] = t[c] }
      reconcile.call(t['key'], rec, want.merge(flags))
    end
  end
  Array(bundle['workflows']).each do |w|
    theme = ModelTheme.where(model_type: w['model_type'], name: w['theme'], deleted_at: nil).first
    next log['skipped, its theme is missing'] << "workflow #{w['key']}" if theme.nil?
    rec = live_or_gone.call(MachineWorkflow.where(model_theme_id: theme.id))
    if rec.nil?
      MachineWorkflow.create!(model_type: w['model_type'], model_theme_id: theme.id, name: w['name'], workflow_order: 1)
      log['created workflow'] << w['key']
    elsif rec.deleted_at.present?
      rec.deleted_at = nil
      rec.name = w['name']
      rec.save!
      log['restored workflow'] << w['key']
    else
      reconcile.call("workflow #{w['key']}", rec, 'name' => w['name'])
    end
  end
  # If a PDC model still couldn't be set up, anything on it is skipped (never
  # created as an orphan) and the model is reported.
  present = MachineModelType.where(model_type: owned, deleted_at: nil).pluck(:model_type)
  missing_models = owned - present
  missing_models.each { |mt| log['model missing (its pieces were skipped)'] << mt }
  on_missing_model = lambda { |item| owned.include?(item['model_type']) && !present.include?(item['model_type']) }
  b = bundle.dup
  %w[attributes methods themes states events].each { |k| b[k] = bundle[k].reject { |x| on_missing_model.call(x) } }
  # GrantRequest's PDC hooks call into the PDC models (e.g. creating a Consent
  # record on save), so they would break GrantRequest saves without them. With
  # any PDC model missing, nothing outside the PDC models is touched.
  unless missing_models.empty?
    gr_type = scope['grant_request']['model_type']
    %w[attributes methods].each do |k|
      held = b[k].select { |x| x['model_type'] == gr_type }
      held.each { |x| log['waits for the PDC models'] << x['key'] }
      b[k] = b[k] - held
    end
    b['shared_slices'].each { |x| log['waits for the PDC models'] << x['key'] }
    b['shared_slices'] = []
    b['stencil_elements'] = []
  end

  # Fields and static dropdown options
  b['attributes'].each do |a|
    rel = ModelAttribute.where(model_type: a['model_type'], name: a['name'])
    live = rel.where(deleted_at: nil).first
    want = { 'description' => a['description'], 'attribute_type' => a['attribute_type'],
             'multi_allowed' => a['multi_allowed'], 'value_model_type' => a['value_model_type'] }
    if live.nil?
      live, how = revive.call(rel, model_type: a['model_type'], name: a['name'])
      want.each { |c, v| live[c] = v }
      live.save!
      log["#{how} field"] << a['key']
    else
      changed = want.reject { |c, v| c == 'multi_allowed' ? lib[:truthy].call(live[c]) == (v ? true : false) : live[c] == v }.keys
      changed.empty? ? log['ok'] << a['key'] : log['field differs (change by hand)'] << "#{a['key']} [#{changed.join(', ')}]"
    end
    next unless a['options'].is_a?(Array)
    a['options'].each do |o|
      key = "#{a['key']} = #{o['value']}"
      rel = ModelAttributeValue.where(model_attribute_id: live.id, value: o['value'])
      want = { 'description' => o['description'], 'display_order' => o['display_order'], 'retired' => o['retired'] }
      if (opt = rel.where(deleted_at: nil).first)
        reconcile.call(key, opt, want)
        next
      end
      opt, how = revive.call(rel, model_attribute_id: live.id, value: o['value'])
      want.each { |c, v| opt[c] = v }
      opt.save!
      log["#{how} option"] << key
    end
  end

  # Instance-specific dropdowns, now that the fields exist (e.g. the Integration
  # Map's Grant Request Themes on a first install)
  log['note'] << "lists refreshed: #{model.dyn_invoke_for(:"PDC Populate Options")}"

  # The models' own forms, from the repo (after the fields and options above,
  # which they refer to). Two things in the repo copy are TRN's: profile
  # restrictions become the PDC Staff Profiles chosen on this record, and
  # dropdown option ids in show/hide conditions become this instance's ids for
  # the same options.
  staff_ids = lib[:selected_profiles].call(model, :pdc_staff_profile).map { |pr| pr.id.to_s }
  profile_keys = scope['stencil_profile_keys'] || []
  volatile = scope['stencil_volatile_keys'] || []
  restricted = false
  map_profiles = nil
  map_profiles = lambda do |node|
    case node
    when Hash
      node.each_with_object({}) do |(k, v), h|
        if profile_keys.include?(k) && Array(v).reject { |x| x.to_s.empty? }.any?
          restricted = true
          h[k] = staff_ids.any? ? staff_ids : v
        else
          h[k] = map_profiles.call(v)
        end
      end
    when Array then node.map { |v| map_profiles.call(v) }
    else node
    end
  end
  Array(bundle['stencils']).each do |sp|
    theme = ModelTheme.where(model_type: sp['model_type'], deleted_at: nil).order(:id).first
    next log['skipped, its theme is missing'] << "form #{sp['key']}" if theme.nil?
    restricted = false
    trn_ids = (scope['stencil_option_ids'] || {}).each_with_object({}) do |(key, ids), h|
      mt, attr = key.split('.', 2)
      h[attr] = ids if mt == sp['model_type']
    end
    unmatched = []
    doc = lib[:rewrite_conditions].call(sp['json'], lambda do |attr, v|
      name = trn_ids[attr] && trn_ids[attr][v]
      next v if name.nil?
      field = ModelAttribute.where(model_type: sp['model_type'], name: attr, deleted_at: nil).first
      opt = field && ModelAttributeValue.where(model_attribute_id: field.id, value: name, deleted_at: nil).first
      unmatched << "#{attr} = #{name}" if opt.nil?
      opt ? opt.id.to_s : v
    end)
    unless unmatched.empty?
      log['note'] << "form #{sp['key']} not written: dropdown option missing (#{unmatched.join(', ')})"
      next
    end
    doc = map_profiles.call(doc)
    # The repo copy has no element uids (they differ per instance), but Fluxx
    # needs one on every element or the record page renders blank: keep the
    # live form's uid where the element is the same, otherwise a new one
    if restricted && staff_ids.empty?
      log['note'] << "form #{sp['key']} not written: choose the PDC Staff Profile (it restricts part of the form)"
      next
    end
    give_uids = nil
    give_uids = lambda do |els, live|
      Array(els).each_with_index do |e, i|
        next unless e.is_a?(Hash)
        was = Array(live)[i]
        same = was.is_a?(Hash) && was['element_type'] == e['element_type'] && was['name'] == e['name']
        e['uid'] = same && !was['uid'].to_s.empty? ? was['uid'] : SecureRandom.uuid if e['uid'].to_s.empty?
        give_uids.call(e['elements'], same ? was['elements'] : nil) if e['elements']
      end
    end
    missing_uid = nil
    missing_uid = lambda { |els| Array(els).any? { |e| e.is_a?(Hash) && (e['uid'].to_s.empty? || missing_uid.call(e['elements'])) } }
    active = Stencil.where(model_type: sp['model_type'], deleted_at: nil).to_a.select { |f| f.enabled && lib[:form_types].call(f).include?('form') }
    live_doc = active.size == 1 ? (JSON.parse(active.first['json'].to_s) rescue {}) : {}
    give_uids.call(doc['elements'], live_doc.is_a?(Hash) ? live_doc['elements'] : nil)
    raw = JSON.generate(doc, ascii_only: true)
    # A PDC model has one form: with exactly one active form, it's brought up
    # to the repo in place; with none, a new form is created (deleted forms are
    # never brought back); with several, a new form named with today's date is
    # created and the others are switched off.
    if active.size == 1
      st = active.first
      if lib[:stencil_sha].call(st['json'], volatile, []) == lib[:stencil_sha].call(raw, volatile, []) && !missing_uid.call(live_doc.is_a?(Hash) ? live_doc['elements'] : nil)
        log['ok'] << "form #{sp['key']}"
      else
        lib[:write_stencil].call(st, raw)
        log['overwrote'] << "form #{sp['key']} (stencil #{st.id})"
      end
      next
    end
    name = active.empty? ? sp['name'] : Time.now.strftime('%Y-%m-%d')
    st = Stencil.new(model_type: sp['model_type'], model_theme_id: theme.id, name: name, enabled: true)
    st.form_type = %w[form list show]
    lib[:write_stencil].call(st, raw)
    log['created form'] << "#{sp['key']} (stencil #{st.id}, #{name})"
    active.each do |old|
      old.enabled = false
      old.save!
      log['switched off (one form per PDC model)'] << "form #{sp['model_type']} #{old.name.to_s.strip} (stencil #{old.id})"
    end
  end
  # Consent permissions for each PDC Grantee Profile. Profiles not chosen keep
  # whatever they have; ones holding these permissions are listed.
  grantees = lib[:selected_profiles].call(model, :pdc_grantee_profile)
  log['note'] << 'no PDC Grantee Profile chosen, so grantees get no Consent permissions' if grantees.empty? && Array(bundle['permissions']).any?
  Array(bundle['permissions']).each do |pm|
    UserProfileRule.where(model_type: pm['model_type'], permission_name: pm['permission_name'], allowed: true)
                   .where.not(user_profile_id: grantees.map(&:id)).each do |other|
      log['note'] << "#{pm['key']} is also held by profile #{(UserProfile.find_by(id: other.user_profile_id)&.name) || other.user_profile_id} (not chosen; left as is)"
    end
  end
  grantees.each do |grantee|
    Array(bundle['permissions']).each do |pm|
      key = "#{pm['key']} for #{grantee.name}"
      rule = UserProfileRule.where(model_type: pm['model_type'], permission_name: pm['permission_name'], user_profile_id: grantee.id).first
      if rule.nil?
        UserProfileRule.create!(model_type: pm['model_type'], permission_name: pm['permission_name'], user_profile_id: grantee.id, allowed: pm['allowed'])
        log['created permission'] << key
      elsif rule.allowed != pm['allowed']
        rule.allowed = pm['allowed']
        rule.save!
        log['overwrote'] << "#{key} [allowed]"
      else
        log['ok'] << key
      end
    end
  end

  # Methods. Secret methods are never written; a soft-deleted one is only
  # un-deleted (its value stays as it was).
  b['methods'].each do |m|
    rel = ModelMethod.where(model_type: m['model_type'], name: m['name'])
    if m['secret']
      next log['ok'] << m['key'] if rel.where(deleted_at: nil).exists?
      gone = rel.where.not(deleted_at: nil).order(deleted_at: :desc).first
      if gone.nil?
        # Created with the repo placeholder, so it's clear what to replace and in
        # what form; never written again after this
        if m['placeholder'].to_s.strip.empty?
          log['secret method missing (enter it by hand)'] << m['key']
        else
          ModelMethod.create!(model_type: m['model_type'], name: m['name'], method_type: m['method_type'] || 'method', unsafe_dyn_method: m['placeholder'])
          log['created (enter the real value)'] << m['key']
        end
        next
      end
      gone.deleted_at = nil
      gone.save!
      log['restored'] << m['key']
      next
    end
    if m['environment_missing']
      log['not written: choose a PDC Environment on this record, then Install again'] << m['key']
      next
    end
    want = { 'method_type' => m['method_type'], 'unsafe_dyn_method' => m['body'] }
    if (live = rel.where(deleted_at: nil).first)
      reconcile.call(m['key'], live, want)
      next
    end
    rec, how = revive.call(rel, model_type: m['model_type'], name: m['name'])
    want.each { |c, v| rec[c] = v }
    rec.save!
    log[how] << m['key']
  end

  # States
  b['states'].each do |s|
    rel = MachineState.where(model_type: s['model_type'], name: s['name'])
    want = { 'description' => s['description'], 'state_type' => s['state_type'], 'state_order' => s['state_order'],
             'allowed_roles' => s['allowed_roles'], 'unsafe_before_validation_enter' => s['before_validation_enter'],
             'unsafe_after_enter' => s['after_enter'] }
    if (live = rel.where(deleted_at: nil).first)
      reconcile.call(s['key'], live, want)
      next
    end
    rec, how = revive.call(rel, model_type: s['model_type'], name: s['name'])
    want.each { |c, v| rec[c] = v }
    rec.save!
    log[how] << s['key']
  end

  # Buttons. Their roles are exactly the PDC Event Roles chosen here; with none
  # chosen, a button keeps its roles, and a button without any gets the role
  # the workflow's other buttons use most.
  state_id = lambda { |mt, name| MachineState.where(model_type: mt, name: name, deleted_at: nil).first&.id }
  chosen_roles = lib[:selected_roles].call(model, :pdc_event_role)
  pick_roles = lambda do |wf|
    next chosen_roles.map(&:id).sort if chosen_roles.any?
    ids = MachineEventRole.where(machine_event_id: MachineEvent.where(machine_workflow_id: wf.id, deleted_at: nil).pluck(:id)).pluck(:role_id)
    common = ids.group_by { |i| i }.max_by { |_, v| v.size }
    common ? [common.first] : []
  end
  roles_wrong = lambda do |ev, wf|
    have = MachineEventRole.where(machine_event_id: ev.id).pluck(:role_id).uniq.sort
    chosen_roles.any? ? have != chosen_roles.map(&:id).sort : have.empty?
  end
  b['events'].each do |e|
    theme = ModelTheme.where(model_type: e['model_type'], name: e['theme'], deleted_at: nil).first
    wf = theme && MachineWorkflow.where(model_theme_id: theme.id, deleted_at: nil).first
    if wf.nil?
      log['workflow missing (create the model first)'] << e['key']
      next
    end
    to_id = state_id.call(e['model_type'], e['to_state'])
    # The states the button shows on (older repo copies also carried an order)
    want_from = Array(e['from_states']).map { |x| state_id.call(e['model_type'], Array(x).first) }
    if to_id.nil? || want_from.any?(&:nil?)
      log['skipped, a state it needs is missing'] << e['key']
      next
    end
    want_from = want_from.uniq.sort
    want = { 'to_state_id' => to_id, 'is_validation_suppressed' => e['is_validation_suppressed'],
             'guard_strategy' => e['guard_strategy'], 'filter' => e['filter'], 'unsafe_guard' => e['guard'] }
    set_links = lambda do |ev|
      have = MachineEventFromState.where(machine_event_id: ev.id).pluck(:from_state_id).uniq.sort
      if have != want_from
        MachineEventFromState.where(machine_event_id: ev.id).destroy_all
        want_from.each { |id| MachineEventFromState.create!(machine_event_id: ev.id, from_state_id: id) }
      end
      if roles_wrong.call(ev, wf) && (want_roles = pick_roles.call(wf)).any?
        MachineEventRole.where(machine_event_id: ev.id).destroy_all
        want_roles.each { |rid| MachineEventRole.create!(machine_event_id: ev.id, role_id: rid) }
      end
    end
    rel = MachineEvent.where(machine_workflow_id: wf.id, button_name: e['button_name'])
    if (live = rel.where(deleted_at: nil).first)
      have = MachineEventFromState.where(machine_event_id: live.id).pluck(:from_state_id).uniq.sort
      extra = []
      extra << 'from_states' if have != want_from
      if roles_wrong.call(live, wf)
        pick_roles.call(wf).any? ? extra << 'roles' : log['button has no role (choose PDC Event Role, then Install again)'] << e['key']
      end
      reconcile.call(e['key'], live, want, extra, -> { set_links.call(live) })
      next
    end
    # A button nobody can click isn't created; choose the role first.
    if pick_roles.call(wf).empty?
      log['button not created: no role (choose PDC Event Role, then Install again)'] << e['key']
      next
    end
    rec, how = revive.call(rel, machine_workflow_id: wf.id, button_name: e['button_name'])
    ActiveRecord::Base.transaction(requires_new: true) do
      want.each { |c, v| rec[c] = v }
      lib[:save_event].call(rec, pick_roles.call(wf), want_from)
      set_links.call(rec)
    end
    log[how] << e['key']
  end

  # The PDC block inside GrantRequest's shared state hooks (only replaced
  # when its markers are there; the rest of the hook isn't PDC's)
  b['shared_slices'].each do |x|
    st = MachineState.where(model_type: x['model_type'], name: x['state'], deleted_at: nil).first
    slice = st && lib[:code_slice].call(st[x['field']], markers)
    want = lib[:code_slice].call(x['body'], markers) || x['body']
    if st.nil?
      log["#{x['state']} state missing (create it in the GrantRequest workflow)"] << x['key']
    elsif slice.nil?
      # At the top, so it always runs (it doesn't trigger another save)
      st[x['field']] = "#{want}\n#{st[x['field']]}"
      st.save!
      log['added PDC block (top of hook)'] << x['key']
    elsif lib[:sha].call(slice) == lib[:sha].call(want)
      log['ok'] << x['key']
    else
      st[x['field']] = st[x['field']].sub(slice) { want }
      st.save!
      log['overwrote'] << x['key']
    end
  end

  # PDC elements on forms, one pass per form that needs anything: updated text
  # or settings for PDC elements already there, and (on the chosen themes'
  # forms and the grantee dashboard page) missing elements and fields, added
  # in a PDC group at the bottom for the admin to move.
  #   an active grant form: copied exactly (visibility, profiles and every other
  #     setting kept); the copy gets the changes and is switched on, the
  #     original is switched off as the rollback. " (PDC)" is added to the name
  #     once. With several active forms, each one is copied.
  #   a switched-off grant form: left alone (it's a rollback)
  #   anything else (the dashboard page): changed in place
  specs = b['stencil_elements']
  # Only the elements Install handles this run (none while a PDC model is missing)
  located = lib[:locate_elements].call(scope, false).select { |id, _| specs.any? { |s| s['id'] == id } }
  by_stencil = Hash.new { |h, k| h[k] = [] }
  located.each { |id, locs| locs.each { |l| by_stencil[l['stencil_id']] << l.merge('id' => id) } }
  plan_by_stencil = missing_models.empty? ? plan['forms'].each_with_object({}) { |f, h| h[f['stencil_id']] = f } : {}
  plan['notes'].each { |n| log['note'] << n } if missing_models.empty?
  group_label = (scope['placement'] || {})['group_label'] || 'PDC'
  # Forms whose PDC elements go without the PDC group (the dashboard page)
  bare_types = Array((scope['placement'] || {})['bare_model_types'])
  attrs_by_name = bundle['attributes'].each_with_object({}) { |a, h| h[[a['model_type'], a['name']]] = a }
  gr_type = scope['grant_request']['model_type']
  # Who sees the PDC pieces: the PDC Grantee Profiles chosen on this record
  grantee_ids = grantees.map { |pr| pr.id.to_s }.sort
  (by_stencil.keys | plan_by_stencil.keys).each do |stencil_id|
    st = Stencil.find(stencil_id)
    next if st.model_type == gr_type && !st.enabled   # switched-off grant forms are rollbacks
    doc = JSON.parse(st['json'].to_s)
    done = []   # [status, what] for this form
    skipped = []
    by_stencil[stencil_id].group_by { |l| l['id'] }.each do |id, here|
      if here.size > 1 || here.any? { |l| Array(l['also_matches']).any? }
        log['duplicate or ambiguous (fix by hand)'] << "#{id} @ stencil #{stencil_id} (#{st.name.to_s.strip})"
        skipped << id
        next
      end
      spec = specs.find { |s| s['id'] == id }
      node = here.first['trail'].inject(doc) { |n, i| n['elements'][i] }
      text = lib[:element_text].call(node)
      if here.first['via'] == 'fingerprint' && ![lib[:sha].call(text), lib[:sha].call(CGI.unescapeHTML(text))].include?(spec['unmarked_sha256'])
        log['unmarked and edited (left alone; review, then replace by hand)'] << "#{id} @ stencil #{stencil_id} (#{st.name.to_s.strip})"
        skipped << id
        next
      end
      text_ok = lib[:sha].call(text) == lib[:sha].call(spec['text'])
      views = (scope['stencil_elements'].find { |s| s['id'] == id } || {})['visibility']
      bad = lib[:element_config_problems].call(node, required_config) + lib[:element_visibility_problems].call(node, views)
      if text_ok && bad.empty?
        log['ok'] << "#{id} @ stencil #{stencil_id} (#{st.name.to_s.strip})"
        next
      end
      cfg = node['config']
      cfg['text'] = spec['text']
      required_config.each { |k, want| cfg[k] = want ? true : '0' unless lib[:truthy].call(cfg[k]) == want }
      lib[:set_element_visibility].call(node, views)
      done << ['wrote element', "#{id} [#{[text_ok ? nil : 'text', *bad].compact.join(', ')}]"]
    end
    # The PDC Grantee Profiles on every PDC element, its group, and the native
    # fields the PDC code reads (elements get them too, since admins move them
    # out of the group)
    if grantee_ids.any?
      set_profiles = lambda do |node, what|
        next unless node.is_a?(Hash)
        next if lib[:profiles_of].call(node) == grantee_ids
        node['visibility'] = (node['visibility'].is_a?(Hash) ? node['visibility'] : {}).merge('user_profile' => grantee_ids)
        done << ['set profiles to the PDC Grantee Profiles', what]
      end
      node_at = lambda { |trail| trail.inject(doc) { |n, i| n.is_a?(Hash) ? Array(n['elements'])[i] : nil } }
      by_stencil[stencil_id].reject { |l| skipped.include?(l['id']) }.each do |l|
        set_profiles.call(node_at.call(l['trail']), l['id'])
        set_profiles.call(node_at.call(l['group_trail']), 'PDC group') if l['group_trail']
      end
      field_names = Array(scope['required_stencil_fields']).select { |r| r['model_type'] == st.model_type }.map { |r| r['attribute'] }
      lib[:stencil_elements].call(JSON.generate(doc)).each do |e|
        next unless e['element']['element_type'] == 'attribute' && field_names.include?(e['element']['name'])
        set_profiles.call(node_at.call(e['trail']), "field #{e['element']['name']}")
      end
    end
    # On a bare form, a PDC group holding PDC elements is replaced by its
    # contents, so grantees see no container (after the profiles above, which
    # find elements by position)
    if bare_types.include?(st.model_type)
      unwrap = lambda do |els|
        Array(els).flat_map do |el|
          next [el] unless el.is_a?(Hash)
          label = el['config'].is_a?(Hash) ? el['config']['label'] : nil
          if el['element_type'] == 'group' && label.to_s.strip == group_label && JSON.generate(el).include?('PDC:ELEMENT')
            done << ['removed the PDC group around PDC elements (no container on the page)', "group of #{Array(el['elements']).size}"]
            unwrap.call(el['elements'])
          else
            el['elements'] = unwrap.call(el['elements']) if el['elements'].is_a?(Array)
            [el]
          end
        end
      end
      doc['elements'] = unwrap.call(doc['elements'])
    end
    f = plan_by_stencil[stencil_id]
    if f && (f['elements'].any? || f['fields'].any?)
      kids = f['elements'].map do |id|
        lib[:new_element].call('text', f['model_type'], 'text' => specs.find { |s| s['id'] == id }['text'], 'profiles' => grantee_ids,
                               'visibility' => (scope['stencil_elements'].find { |s| s['id'] == id } || {})['visibility'])
      end
      kids += f['fields'].map do |name|
        a = attrs_by_name[[f['model_type'], name]] || {}
        lib[:new_element].call('field', f['model_type'], 'name' => name, 'label' => a['description'] || name, 'profiles' => grantee_ids,
                               'template' => (scope['stencil_field_templates'] || {})["#{f['model_type']}.#{name}"])
      end
      doc['elements'] = Array(doc['elements']) +
                        (bare_types.include?(f['model_type']) ? kids : [lib[:new_element].call('group', f['model_type'], 'label' => group_label, 'elements' => kids, 'profiles' => grantee_ids)])
      (f['elements'] + f['fields'].map { |n| "field #{n}" }).each { |what| done << ['added to form (bottom; move it where it belongs)', what] }
    end
    next if done.empty?
    raw = JSON.generate(doc, ascii_only: true)
    if st.model_type == gr_type
      copy = st.dup
      base = st.name.to_s.strip.sub(/\s*\(PDC Removed\)\z/, '')   # a form Uninstall made goes back to "(PDC)"
      copy['name'] = base.end_with?('(PDC)') ? base : "#{base} (PDC)"
      copy.enabled = true
      lib[:write_stencil].call(copy, raw)
      st.enabled = false
      st.save!
      log['copied form (changes on the copy; original kept, switched off)'] << "stencil #{st.id} -> #{copy.id} (#{copy.name})"
      target = "stencil #{copy.id} (#{copy.name})"
    else
      lib[:write_stencil].call(st, raw)
      target = "stencil #{st.id} (#{st.name.to_s.strip})"
    end
    done.each { |status, what| log[status] << "#{what} @ #{target}" }
  end

  { 'mode' => "from #{lib[:repo_label].call(model)}" }
end

# Worked out before anything changes, so the forms it touches are in the snapshot
plan = lib[:placement_plan].call(model, bundle['scope'])
# Which grant forms exist now, so Restore Previous can remove the copies made
form_sets = [{ 'table' => 'FormSet', 'key' => 'grant forms', 'find' => { 'model_type' => bundle['scope']['grant_request']['model_type'] } }]
rules = lib[:selected_profiles].call(model, :pdc_grantee_profile).flat_map do |gp|
  Array(bundle['permissions']).map do |pm|
    { 'table' => 'UserProfileRule', 'key' => "#{pm['key']} for #{gp.name}",
      'find' => { 'model_type' => pm['model_type'], 'permission_name' => pm['permission_name'], 'user_profile_id' => gp.id } }
  end
end
targets = lib[:snapshot_targets].call(bundle, plan['forms'].map { |f| f['stencil_id'] }, form_sets + rules)
lib[:run_with_snapshots].call(model, 'Install', 'install_results', targets, save_now, install)
