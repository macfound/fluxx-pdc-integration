# PDC Uninstall
#
# The Uninstall button on the deploy model. Removes what PDC owns, as listed
# in deploy/pdc-install-bundle.json, and lists anything it isn't sure about
# for someone to review and delete by hand.
#
# Removed (soft-deleted where Fluxx supports it, so Restore Previous can
# bring everything back with its original id):
#   - PDC elements on forms (by PDC:ELEMENT marker, or by fingerprint when the
#     content is the unedited repo copy), the GrantRequest PDC fields on
#     forms, and a group left holding only PDC elements. Grant forms are never
#     changed: each active one with PDC is copied as "<name> (PDC Removed)"
#     without the PDC pieces and switched on, and the form with PDC is switched
#     off, so either can be used. Switched-off forms are left alone.
#   - the ###PDC_CODE### block in GrantRequest's granted hook
#   - PDC buttons, states, methods and fields (the secret client ID / secret
#     methods are never touched)
#   - the PDC models themselves, as Fluxx removes a model: workflows, forms,
#     themes, then the model. Fluxx's cleanup then soft-deletes everything
#     else tied to each model, records included. Restore Previous brings back
#     the configuration (the snapshot lists those settings first), not the
#     records
# Listed for review, never removed:
#   - PDC-looking elements that were edited, are ambiguous, or have no marker
#     and don't match the repo; groups that also hold other content
#   - methods, states and buttons on the PDC models that PDC didn't ship
#     (they go with their model, and come back with Restore Previous)
#   - this deploy model: delete it last, once you're sure
#
# Before changing anything, the whole PDC configuration is saved to
# previous_configuration; Restore Previous puts it back. Results go to
# uninstall_results.

require 'json'
require 'time'
require 'cgi'

lib = model.dyn_invoke_for(:"PDC Installer Lib") unless defined?(lib) && lib
bundle = (defined?(pdc_bundle) && pdc_bundle) || lib[:fetch_repo_json].call(model, 'deploy/pdc-install-bundle.json')
save_now = defined?(pdc_one_off) && pdc_one_off ? true : false

uninstall = lambda do |log|
  scope = bundle['scope']
  gr = scope['grant_request']
  owned = scope['owned_model_types'].keys - [model.class.name]
  now = Time.now
  soft_delete = lambda do |rec, key|
    rec.deleted_at = now
    rec.save!
    log['removed'] << key
  end

  # 1. Forms. Work out which elements are PDC's, then remove them; a group
  # whose children are all being removed goes too.
  specs = bundle['stencil_elements']
  # Only elements PDC still ships: a marker for something no longer in the scope
  # (e.g. the dropped consent Q&A page) is someone else's content now
  located = lib[:locate_elements].call(scope, false).select { |id, _| specs.any? { |sp| sp['id'] == id } }
  removable = Hash.new { |h, k| h[k] = {} }   # stencil id => { trail => label }
  located.each do |id, locs|
    spec = specs.find { |s| s['id'] == id }
    locs.each do |l|
      where = "#{id} @ stencil #{l['stencil_id']} (#{l['stencil_name'].to_s.strip})"
      if Array(l['also_matches']).any?
        log['review: looks like more than one PDC element'] << where
      elsif l['via'] == 'marker' || (spec && [l['sha256'], l['sha256_decoded']].include?(spec['unmarked_sha256']))
        removable[l['stencil_id']][l['trail']] = id
      else
        log['review: no marker and edited, left on the form'] << where
      end
    end
  end
  conn = Stencil.connection
  gr['attributes'].each do |name|
    Stencil.where(model_type: gr['model_type'], deleted_at: nil).where("json LIKE #{conn.quote('%' + name + '%')}").each do |st|
      lib[:stencil_elements].call(st['json']).each do |e|
        removable[st.id][e['trail']] = "field #{name}" if e['element']['element_type'] == 'attribute' && e['element']['name'] == name
      end
    end
  end
  removable.each do |stencil_id, trails|
    # One form that can't be handled is listed and skipped; the rest carry on
    begin
      st = Stencil.find(stencil_id)
      next if st.model_type == gr['model_type'] && !st.enabled   # switched-off grant forms are left as they are
      doc = JSON.parse(st['json'].to_s)
      node_at = lambda { |trail| trail.inject(doc) { |n, i| n['elements'][i] } }
      label = lambda { |node| (node['config'].is_a?(Hash) && node['config']['label']) || node['label'] || 'group' }
      # Marked PDC elements being removed (fingerprint matches have no marker to count)
      marker_of = lambda { |id| /PDC:ELEMENT\s+id=#{Regexp.escape(id.to_s)}(?![\w-])/ }
      removed_ids = trails.select { |t, v| lib[:element_text].call(node_at.call(t)).to_s =~ marker_of.call(v) }.values
      # Collapse upward: a parent group whose children are all removable is
      # removed instead (groups only; other containers stay).
      loop do
        parents = trails.keys.select { |t| t.size > 1 }.map { |t| t[0..-2] }.uniq.reject { |p| trails.key?(p) }
        collapsed = parents.select do |p|
          next false unless node_at.call(p)['element_type'] == 'group'
          kids = Array(node_at.call(p)['elements']).each_index.map { |i| p + [i] }
          kids.all? { |k| trails.key?(k) }
        end
        break if collapsed.empty?
        collapsed.each do |p|
          trails.delete_if { |t, _| t[0, p.size] == p }
          trails[p] = "group '#{label.call(node_at.call(p))}'"
        end
      end
      trails.delete_if { |t, _| (1...t.size).any? { |n| trails.key?(t[0, n]) } }
      # Groups that keep other content stay, and are listed (once saved).
      kept_notes = trails.keys.select { |t| t.size > 1 }.map { |t| t[0..-2] }.uniq.map do |p|
        kept = node_at.call(p)
        what = kept['element_type'] == 'group' ? 'group kept, it holds other content' : "#{kept['element_type']} container kept (only groups are removed)"
        ["review: #{what}", "'#{label.call(kept)}'"]
      end
      # Remove deepest/last first so earlier trails stay valid.
      trails.keys.sort.reverse.each do |t|
        parent = t.size == 1 ? doc : node_at.call(t[0..-2])
        parent['elements'].delete_at(t.last)
      end
      new_raw = JSON.generate(doc, ascii_only: true)
      count = lambda do |raw, id|
        lib[:stencil_elements].call(raw).count { |e| lib[:element_text].call(e['element']).to_s =~ marker_of.call(id) }
      end
      leftover = removed_ids.uniq.select { |id| count.call(new_raw, id) != count.call(st['json'].to_s, id) - removed_ids.count(id) }
      raise "stencil #{stencil_id}: PDC element #{leftover.join(', ')} not removed as expected; nothing saved" if leftover.any?
      if st.model_type == gr['model_type']
        # A grant form is never changed: an exact copy (every setting and any
        # customisation kept) without the PDC elements is switched on, and the
        # form with PDC is switched off, so either can be switched back on
        copy = st.dup
        base = st.name.to_s.strip.sub(/\s*\(PDC( Removed)?\)\z/, '')
        copy['name'] = "#{base} (PDC Removed)"
        copy.enabled = true
        lib[:write_stencil].call(copy, new_raw)
        st.enabled = false
        st.save!
        log['copied form without PDC (the form with PDC kept, switched off)'] << "stencil #{st.id} -> #{copy.id} (#{copy.name})"
        where = "stencil #{copy.id} (#{copy.name})"
      else
        lib[:write_stencil].call(st, new_raw)
        where = "stencil #{stencil_id} (#{st.name.to_s.strip})"
      end
      trails.values.sort.each { |what| log['removed from form'] << "#{what} @ #{where}" }
      kept_notes.each { |key, what| log[key] << "#{what} @ #{where}" }
    rescue => e
      where = Array(e.backtrace).find { |b| b.include?('eval') } || Array(e.backtrace).first
      log['review: could not remove PDC elements from this form, left as it was'] << "stencil #{stencil_id}: #{e.class}: #{e.message} (#{where})"
    end
  end

  # 2. The PDC block in GrantRequest's shared hooks
  bundle['shared_slices'].each do |x|
    st = MachineState.where(model_type: x['model_type'], name: x['state'], deleted_at: nil).first
    slice = st && lib[:code_slice].call(st[x['field']], scope['markers'])
    if slice.nil?
      log['review: PDC block not found in hook'] << x['key']
      next
    end
    st[x['field']] = st[x['field']].sub(/\n*#{Regexp.escape(slice)}\n*/) { "\n\n" }.strip
    st.save!
    log['removed'] << "#{x['key']} (PDC block only)"
  end

  # 3. Buttons, states, methods, fields
  bundle['events'].each do |e|
    t = { 'table' => 'MachineEvent', 'find' => { 'model_type' => e['model_type'], 'theme' => e['theme'], 'button_name' => e['button_name'] } }
    (rec = lib[:snapshot_find].call(t, true)) ? soft_delete.call(rec, e['key']) : log['already gone'] << e['key']
  end
  bundle['states'].each do |s|
    rec = MachineState.where(model_type: s['model_type'], name: s['name'], deleted_at: nil).first
    rec ? soft_delete.call(rec, s['key']) : log['already gone'] << s['key']
  end
  bundle['methods'].each do |m|
    # The secret methods (PDC client ID and secret) are never touched; if their
    # model is removed below, Fluxx keeps their values and Install brings them back
    next log['kept (secret, never touched)'] << m['key'] if m['secret']
    rec = ModelMethod.where(model_type: m['model_type'], name: m['name'], deleted_at: nil).first
    rec ? soft_delete.call(rec, m['key']) : log['already gone'] << m['key']
  end
  bundle['attributes'].each do |a|
    rec = ModelAttribute.where(model_type: a['model_type'], name: a['name'], deleted_at: nil).first
    rec ? soft_delete.call(rec, a['key']) : log['already gone'] << a['key']
  end

  # 4. Anything else on the PDC models wasn't shipped by PDC; it goes with
  # its model below, so it's listed (Restore Previous brings it back)
  ModelMethod.where(model_type: owned, deleted_at: nil).each { |mm| log['review: not shipped by PDC, removed with its model'] << "#{mm.model_type}##{mm.name}" }
  MachineState.where(model_type: owned, deleted_at: nil).each { |s| log['review: not shipped by PDC, removed with its model'] << "#{s.model_type}:#{s.name}" }
  ModelTheme.where(model_type: owned, deleted_at: nil).each do |th|
    MachineWorkflow.where(model_theme_id: th.id, deleted_at: nil).each do |wf|
      MachineEvent.where(machine_workflow_id: wf.id, deleted_at: nil).each { |ev| log['review: not shipped by PDC, removed with its model'] << "#{th.model_type}/#{th.name}>#{ev.button_name}" }
    end
  end

  # 5. The PDC models themselves, as Fluxx removes a model: their workflows,
  # forms and themes, then the model. Fluxx's own cleanup then soft-deletes
  # the rest tied to each model, records included; the snapshot taken before
  # this run lists the configuration rows so Restore Previous can bring them
  # back (records are left to a separate recovery).
  ModelTheme.where(model_type: owned).each do |th|
    MachineWorkflow.where(model_theme_id: th.id, deleted_at: nil).each { |wf| soft_delete.call(wf, "workflow #{th.model_type}/#{th.name}") }
  end
  Stencil.where(model_type: owned, deleted_at: nil).each { |st| soft_delete.call(st, "form #{st.model_type} #{st.name.to_s.strip} (stencil #{st.id})") }
  ModelTheme.where(model_type: owned, deleted_at: nil).each { |th| soft_delete.call(th, "theme #{th.model_type}/#{th.name}") }
  MachineModelType.where(model_type: owned, deleted_at: nil).each do |mt|
    count = (Object.const_get(mt.model_type).where(deleted_at: nil).count rescue nil)
    soft_delete.call(mt, "model #{mt.name} (#{mt.model_type})#{count ? ", with its #{count} records" : ''}")
  end
  log['delete by hand in Fluxx when sure'] << "this deploy model (#{model.class.name}), last: Restore Previous lives here"

  { 'mode' => 'removed PDC components' }
end

owned_types = bundle['scope']['owned_model_types'].keys - [model.class.name]
# Which grant forms exist now, so Restore Previous can remove the copies made
form_sets = [{ 'table' => 'FormSet', 'key' => 'grant forms', 'find' => { 'model_type' => bundle['scope']['grant_request']['model_type'] } }]
lib[:run_with_snapshots].call(model, 'Uninstall', 'uninstall_results', lib[:snapshot_targets].call(bundle, [], form_sets), save_now, uninstall, owned_types)
