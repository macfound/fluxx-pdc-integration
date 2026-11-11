# PDC Bootstrap Deploy Model
#
# Builds (or refreshes) the deploy model itself from deploy/installer/
# deploy-model.json in the repo: its theme, workflow and blank form if Fluxx
# didn't make them, then its attributes, snapshot document type,
# installer methods, states, workflow buttons, and its form (stencil/layout.json overwrites the stencil
# Fluxx created). Runs on whatever model type it's attached to
# (model.class), so the deploy model's name doesn't matter.
#
# Called by the pasted Before New when the first New form opens, by After
# Create when that record is saved (to create the buttons with the chosen
# Installer Role), and later by the "Update Installer" button. Safe to re-run: missing pieces are created, and
# changed method/state bodies and the form are replaced with the repo copy
# (all of it lives in the repo, so nothing here needs a backup).
#
# It never touches previous_configuration / current_configuration: those
# point to the PDC configuration snapshots used by Restore Previous.
# Returns, and stores in installer_results, what it did.

require 'json'
require 'net/http'
require 'uri'
require 'cgi'
require 'time'
require 'securerandom'

mt = model.class.name
log = []

# Repo location: handed over by Before New on the first run, else the record's fields.
handoff = model.instance_variable_get(:@pdc_bootstrap) || {}
# The PDC Repo Settings method covers a record whose fields didn't stick.
saved_repo = (model.dyn_invoke_for(:"PDC Repo Settings") rescue nil)
saved_repo = {} unless saved_repo.is_a?(Hash)
field = lambda { |f| model.respond_to?(f) ? model.public_send(f).to_s.strip.presence : nil }
repo_url = handoff['repo_url'] || field.call(:repo_url) || saved_repo['repo_url']
repo_ref = handoff['repo_ref'] || field.call(:repo_ref) || saved_repo['repo_ref']
repo_ref = 'main' if repo_ref.blank?

# The commit repo_ref points to now (looked up once), recorded on the record
# and in the results. Same as lib[:github_commit], which may not exist yet on
# a first run.
commit = nil
commit_note = nil
find_commit = lambda do
  return if commit || commit_note
  if repo_ref.to_s =~ /\A\h{40}\z/
    commit = repo_ref
    return
  end
  m = repo_url.to_s.strip.match(%r{github\.com[/:]([^/]+)/([^/]+?)(?:\.git)?/?\z})
  return (commit_note = "repo_url isn't a github.com repository") unless m
  begin
    uri = URI.parse("https://api.github.com/repos/#{m[1]}/#{m[2]}/commits/#{repo_ref}")
    req = Net::HTTP::Get.new(uri)
    req['Accept'] = 'application/vnd.github.sha'
    req['User-Agent'] = 'fluxx-pdc-installer'
    resp = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 20) { |http| http.request(req) }
    sha = resp.body.to_s.strip
    resp.code == '200' && sha =~ /\A\h{40}\z/ ? (commit = sha) : (commit_note = "GitHub answered HTTP #{resp.code}")
  rescue => e
    commit_note = "#{e.class}: #{e.message}"
  end
end
source_label = lambda { commit && commit != repo_ref ? "#{repo_ref} @ #{commit[0, 7]}" : (commit ? commit[0, 7] : repo_ref) }

# Files are fetched at the commit found above when there is one: GitHub caches
# a branch's raw files for a few minutes after a push, so fetching by branch
# name can return the previous version while the commit is already the new one.
fetch = lambda do |path|
  m = repo_url.to_s.strip.match(%r{github\.com[/:]([^/]+)/([^/]+?)(?:\.git)?/?\z})
  raise "repo_url must be a github.com repository URL, got #{repo_url.inspect}" unless m
  encoded = path.split('/').map { |p| CGI.escape(p).gsub('+', '%20') }.join('/')
  uri = URI.parse("https://raw.githubusercontent.com/#{m[1]}/#{m[2]}/#{commit || repo_ref}/#{encoded}")
  resp = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
    http.request(Net::HTTP::Get.new(uri))
  end
  raise "Could not fetch #{path} at '#{repo_ref}' (HTTP #{resp.code})" unless resp.code == '200'
  resp.body.to_s.dup.force_encoding('UTF-8')
end

same = lambda do |a, b|
  norm = lambda { |t| t.to_s.gsub("\r\n", "\n").split("\n").map(&:rstrip).join("\n").strip }
  norm.call(a) == norm.call(b)
end

# Can this user save custom Ruby? Tested by doing it inside a savepoint that
# is always rolled back, so it works whatever Fluxx calls the permission.
# (requires_new: inside a save, a plain nested transaction can't roll back.)
ruby_denied =
  begin
    ActiveRecord::Base.transaction(requires_new: true) do
      ModelMethod.create!(model_type: mt, method_type: 'method', name: 'PDC Permission Probe', unsafe_dyn_method: "'ok'")
      raise ActiveRecord::Rollback
    end
    nil
  rescue => e
    "#{e.class}: #{e.message}"
  end

result =
  begin
    if ruby_denied
      raise "#{User.find_current_user rescue 'This user'} cannot save custom Ruby in Fluxx, which the PDC " \
            "installer needs. Ask a Fluxx admin with Ruby access to run this. (Fluxx said: #{ruby_denied})"
    end
    raise "repo_ref #{repo_ref.inspect} isn't a branch, tag or commit name" unless repo_ref.to_s =~ %r{\A[\w.\-/]+\z} && !repo_ref.to_s.include?('..')
    find_commit.call
    log << (commit ? "commit: #{commit} (#{repo_ref})" : "commit: unknown (#{commit_note})")
    spec = JSON.parse(fetch.call('deploy/installer/deploy-model.json'))

    # 0. The deploy model's theme, workflow and form. Fluxx normally creates
    # them with the model; anything missing is brought back if soft-deleted,
    # else created, so nothing is assumed to exist but the model itself.
    model_name = (MachineModelType.where(model_type: mt).order(:id).first&.name).presence || mt
    pick = lambda { |rel| rel.where(deleted_at: nil).order(:id).first || rel.where.not(deleted_at: nil).order(deleted_at: :desc).first }
    theme0 = pick.call(ModelTheme.where(model_type: mt))
    if theme0.nil?
      theme0 = ModelTheme.create!(model_type: mt, name: model_name, label: "#{model_name} Default Theme")
      log << "theme #{theme0.name}: created"
    elsif theme0.deleted_at.present?
      theme0.deleted_at = nil
      theme0.save!
      log << "theme #{theme0.name}: restored"
    end
    wf0 = pick.call(MachineWorkflow.where(model_theme_id: theme0.id))
    if wf0.nil?
      MachineWorkflow.create!(model_type: mt, model_theme_id: theme0.id, name: model_name, workflow_order: 1)
      log << "workflow #{model_name}: created"
    elsif wf0.deleted_at.present?
      wf0.deleted_at = nil
      wf0.save!
      log << "workflow #{wf0.name}: restored"
    end
    form_types0 = lambda { |st| st.form_type.is_a?(Array) ? st.form_type.map(&:to_s) : st.form_type.to_s.split(/[,\s]+/) }
    unless Stencil.where(model_type: mt, deleted_at: nil).to_a.any? { |st| form_types0.call(st).include?('form') }
      st0 = Stencil.where(model_type: mt, model_theme_id: theme0.id).where.not(deleted_at: nil).order(deleted_at: :desc).first
      if st0
        st0.deleted_at = nil
        st0.save!
        log << "stencil #{st0.id}: restored"
      else
        st0 = Stencil.new(model_type: mt, model_theme_id: theme0.id, name: 'default', enabled: true, json: '{"elements":[]}')
        st0.form_type = %w[form list show]
        st0.save!
        log << "stencil #{st0.id}: created"
      end
    end

    # 1. Attributes
    spec['attributes'].each do |a|
      existing = ModelAttribute.where(model_type: mt, name: a['name'], deleted_at: nil).first
      if existing
        # Keep the field's type and single/multiple choice in line with the repo
        want_multi = a['multi_allowed'] ? true : false
        if (existing.multi_allowed ? true : false) != want_multi || existing.attribute_type != a['attribute_type']
          existing.multi_allowed = want_multi
          existing.attribute_type = a['attribute_type']
          existing.save!
          log << "attribute #{a['name']}: updated"
        else
          log << "attribute #{a['name']}: exists"
        end
      else
        ModelAttribute.create!(model_type: mt, name: a['name'], description: a['description'],
                               attribute_type: a['attribute_type'], multi_allowed: a['multi_allowed'] ? true : false)
        log << "attribute #{a['name']}: created"
      end
    end

    Array(spec['retired_attributes']).each do |name|
      gone = ModelAttribute.where(model_type: mt, name: name, deleted_at: nil).first
      next if gone.nil?
      gone.deleted_at = Time.now
      gone.save!
      log << "attribute #{name}: removed (no longer used)"
    end

    # Document type for configuration snapshots (Install, Uninstall and
    # Restore Previous save each snapshot as a text document of this type)
    # The installer writes these documents itself; nobody uploads one, so the
    # type must never be required (a required type blocks saving the record).
    dt_name = spec['snapshot_document_type']
    dt = ModelDocumentType.where(model_type: mt, name: dt_name).where('retired IS NULL OR retired = ?', false).first
    dt_cols = ModelDocumentType.column_names
    if dt.nil?
      attrs = { model_type: mt, name: dt_name, doc_label: 'default', permission_name: 'read_only',
                model_theme_id: ModelTheme.where(model_type: mt, deleted_at: nil).order(:id).first&.id }
      attrs[:required] = false if dt_cols.include?('required')
      ModelDocumentType.create!(attrs)
      log << "document type #{dt_name}: created"
    elsif (dt_cols.include?('required') && dt.required) || (dt_cols.include?('required_state') && dt.required_state.present?)
      dt.required = false if dt_cols.include?('required')
      dt.required_state = nil if dt_cols.include?('required_state')
      dt.save!
      log << "document type #{dt_name}: updated"
    else
      log << "document type #{dt_name}: exists"
    end

    # 2. Installer methods (bodies fetched from the repo)
    spec['methods'].each do |m|
      body = fetch.call(m['path'])
      mm = ModelMethod.where(model_type: mt, name: m['name'], deleted_at: nil).first
      if mm.nil?
        ModelMethod.create!(model_type: mt, method_type: m['method_type'] || 'method', name: m['name'], unsafe_dyn_method: body)
        log << "method #{m['name']}: created"
      elsif same.call(mm.unsafe_dyn_method, body) && mm.method_type == (m['method_type'] || 'method')
        log << "method #{m['name']}: up to date"
      else
        mm.unsafe_dyn_method = body
        mm.method_type = m['method_type'] || 'method'
        mm.save!
        log << "method #{m['name']}: updated"
      end
    end

    # 3. States (one per button; each hook keeps the previous state, then runs a method)
    states = {}
    spec['states'].each_with_index do |s, i|
      hook = s['invokes'] ? "#{spec['state_hook_prefix']}\nmodel.dyn_invoke_for(:\"#{s['invokes']}\")".strip : nil
      st = MachineState.where(model_type: mt, name: s['name'], deleted_at: nil).first
      # Fluxx may have created its own starting state under another name; use it
      st ||= MachineState.where(model_type: mt, state_type: 'new', deleted_at: nil).order(:id).first if s['state_type'] == 'new'
      if st.nil?
        attrs = { model_type: mt, name: s['name'], description: s['description'], state_type: s['state_type'],
                  state_order: i + 1, allowed_roles: '[]', unsafe_before_validation_enter: hook }
        attrs[:external_description] = s['description'] if MachineState.column_names.include?('external_description')   # as the GUI sets it
        st = MachineState.create!(attrs)
        log << "state #{s['name']}: created"
      elsif hook && !same.call(st.unsafe_before_validation_enter, hook)
        st.unsafe_before_validation_enter = hook
        st.save!
        log << "state #{s['name']}: hook updated"
      else
        log << "state #{s['name']}: exists"
      end
      states[s['name']] = st
    end
    # The first record must start in the state the buttons appear on
    start = states['new']
    # (Fluxx has already created a temporary record when Before New runs, with
    # no state; a record without a state starts in "new".)
    if start && model.respond_to?(:state=) && model.state.blank?
      model.state = start.name
      log << "record: starts in state #{start.name}"
    end

    # 4. The deploy model's own form: overwrite the stencil Fluxx created with
    # the repo layout. This is the only installer step that edits it; the other
    # methods just write field values the layout renders.
    layout = JSON.parse(fetch.call(spec['stencil_layout']))
    attr_types = ModelAttribute.where(model_type: mt, deleted_at: nil).pluck(:name, :attribute_type).to_h
    visibility = lambda do
      { 'visible_show' => true, 'visible_form' => true, 'advanced_filter' => '1',
        'advanced_query' => JSON.generate('group_type' => 'and', 'conditions' => [], 'relationship_filter_model_type' => mt),
        'advanced_sort' => '[]' }
    end
    build = nil
    build = lambda do |el|
      if el['group']
        { 'element_type' => 'group', 'name' => 'group', 'label' => el['group'],
          'config' => { 'label' => el['group'], 'collapsible' => el['collapsible'] ? '1' : '0', 'default_open' => '0',
                        'disable_lazy_load' => '0', 'hide_label' => '0', 'reveal_if_type' => 'show', 'show_in_toc' => '0' },
          'visibility' => visibility.call,
          'styling' => { 'alignment' => 'left', 'border_radius' => '7', 'padding_top' => '7', 'padding_bottom' => '7',
                         'padding_left' => '7', 'padding_right' => '7', 'border_top_enabled' => true,
                         'border_bottom_enabled' => true, 'border_left_enabled' => true, 'border_right_enabled' => true },
          'uid' => SecureRandom.uuid, 'elements' => el['elements'].map { |c| build.call(c) } }
      elsif el['raw']
        # An element copied as Fluxx stores it (e.g. a documents list): fresh
        # uids, and filters pointed at this model type
        fresh = nil
        fresh = lambda do |node|
          case node
          when Hash
            copied = node.each_with_object({}) do |(k, v), h|
              h[k] = if k == 'uid' then SecureRandom.uuid
                     elsif k == 'advanced_query' && v.is_a?(String) then v.gsub(/"relationship_filter_model_type":"[^"]*"/, %("relationship_filter_model_type":"#{mt}"))
                     else fresh.call(v)
                     end
            end
            copied['uid'] ||= SecureRandom.uuid if copied.key?('element_type')
            copied
          when Array then node.map { |v| fresh.call(v) }
          else node
          end
        end
        out = fresh.call(el['raw'])
        # Fluxx's form builder expects every element to carry these, as the
        # ones it saves itself do
        out['uid'] ||= SecureRandom.uuid
        out['config'] ||= {}
        out['visibility'] ||= visibility.call
        out['styling'] ||= { 'alignment' => 'left' }
        out
      elsif el['field']
        raise "layout field #{el['field']} is not an attribute on #{mt}" unless attr_types.key?(el['field'])
        # Fluxx stores Required as true (and not-required as "0")
        config = { 'label' => el['label'], 'required' => el['required'] ? true : '0' }
        config['show_as_radio_buttons'] = '0' if attr_types[el['field']] == 'multi_value' && el['config'].nil?
        config.merge!(el['config']) if el['config'].is_a?(Hash)
        config.merge!('allow_rich_text' => '0', 'trackable' => '0', 'trackable_workflow' => '0') if attr_types[el['field']] == 'text'
        vis = visibility.call
        vis['lock_field'] = true if el['lock']
        { 'element_type' => 'attribute', 'name' => el['field'], 'label' => el['label'], 'config' => config,
          'visibility' => vis, 'styling' => { 'alignment' => 'left' }, 'uid' => SecureRandom.uuid }
      else
        # list_only: shown in the list view and nowhere else, as Fluxx stores
        # it (visible_list, without visible_show / visible_form)
        vis = visibility.call
        vis = vis.reject { |k, _| k.start_with?('visible_') }.merge('visible_list' => true) if el['list_only']
        { 'element_type' => 'text', 'name' => 'text',
          'config' => { 'text' => fetch.call(el['text_path']), 'strip_html' => '0', 'allow_script' => '0' },
          'visibility' => vis, 'styling' => { 'alignment' => 'left' }, 'uid' => SecureRandom.uuid }
      end
    end
    new_elements = layout['elements'].map { |el| build.call(el) }
    without_uids = nil
    without_uids = lambda do |node|
      case node
      when Hash then node.reject { |k, _| k == 'uid' }.transform_values { |v| without_uids.call(v) }
      when Array then node.map { |v| without_uids.call(v) }
      else node
      end
    end
    form_types = lambda { |st| st.form_type.is_a?(Array) ? st.form_type.map(&:to_s) : st.form_type.to_s.split(/[,\s]+/) }
    stencils = Stencil.where(model_type: mt, deleted_at: nil).to_a
    target = stencils.select { |st| form_types.call(st).include?('form') }.max_by { |st| [st.enabled ? 1 : 0, st.updated_at.to_i] }
    if target.nil?
      log << "stencil: not found for #{mt} (#{stencils.size} without a form type); create the form in the GUI and click Update Installer"
    else
      old_doc = (JSON.parse(target['json'].to_s) rescue nil)
      old_doc = {} unless old_doc.is_a?(Hash)
      new_doc = old_doc.merge('elements' => new_elements)   # keep any other settings Fluxx stores
      if without_uids.call(old_doc['elements']) == without_uids.call(new_elements)
        log << "stencil #{target.id}: up to date"
      else
        raw = JSON.generate(new_doc, ascii_only: true)
        target['json'] = raw
        target.save!
        raise "stencil #{target.id} did not save intact" unless Stencil.where(id: target.id).pluck(:json).first.to_s == raw
        log << "stencil #{target.id}: overwritten with the repo layout"
      end
      others = stencils.map(&:id) - [target.id]
      log << "stencil: left other #{mt} stencils alone (#{others.join(', ')})" unless others.empty?
    end

    # 5. Workflow buttons on the workflow Fluxx created with the model's theme
    theme = ModelTheme.where(model_type: mt, deleted_at: nil).order(:id).first
    workflow = theme && MachineWorkflow.where(model_theme_id: theme.id, deleted_at: nil).first
    raise "No workflow for #{mt}'s theme" if workflow.nil?
    # The role chosen in the required Installer Role field. When the first New
    # form opens nothing is chosen yet, so the buttons are created by After
    # Create once the record is saved. Without a choice, the role the existing
    # buttons already use is kept.
    # Every Installer Role chosen; with none chosen, the roles the buttons
    # already have are kept
    chosen = (model.dyn_invoke_for(:"PDC Installer Lib")[:selected_roles].call(model, spec['button_role_field'].to_sym) rescue []) || []
    existing_role_ids = MachineEventRole.where(machine_event_id: MachineEvent.where(machine_workflow_id: workflow.id, deleted_at: nil).select(:id)).pluck(:role_id).uniq
    roles = chosen.any? ? chosen : Role.where(id: existing_role_ids, deleted_at: nil).to_a
    role = roles.first
    if roles.empty?
      log << (handoff['phase'] == 'before_new' ? "buttons: waiting (they're created when this record is saved with an Installer Role)" :
                                  "buttons: not created (choose an Installer Role, save, then click Update Installer or create the buttons' role in the workflow editor)")
    end
    filter = JSON.generate([
      { 'name' => 'advanced_query', 'value' => JSON.generate('group_type' => 'and', 'conditions' => [], 'relationship_filter_model_type' => mt) },
      { 'name' => 'advanced_sort', 'value' => '[]' },
      { 'name' => 'type', 'value' => 'MachineModel' },
      { 'name' => 'filter_type', 'value' => 'MachineModel' }
    ])
    spec['events'].each do |e|
      next if role.nil? && !MachineEvent.where(machine_workflow_id: workflow.id, button_name: e['button_name'], deleted_at: nil).exists?
      existing = MachineEvent.where(machine_workflow_id: workflow.id, button_name: e['button_name'], deleted_at: nil).first
      if existing
        have = MachineEventRole.where(machine_event_id: existing.id).pluck(:role_id).uniq.sort
        # (a role deleted from Fluxx doesn't count: nobody can click with it)
        live_have = Role.where(id: have, deleted_at: nil).pluck(:id)
        if roles.any? && (live_have.empty? || (chosen.any? && have != chosen.map(&:id).sort))
          MachineEventRole.where(machine_event_id: existing.id).destroy_all
          roles.each { |rl| MachineEventRole.create!(machine_event_id: existing.id, role_id: rl.id) }
          log << "button #{e['button_name']}: roles set to #{roles.map(&:name).join(', ')}"
        else
          log << "button #{e['button_name']}: exists"
        end
        next
      end
      begin
        # Fluxx won't save a button without a role, so its roles and from-states
        # are attached before the first save
        ActiveRecord::Base.transaction(requires_new: true) do
          ev = MachineEvent.new(machine_workflow_id: workflow.id, button_name: e['button_name'],
                                to_state_id: states.fetch(e['to_state']).id, is_validation_suppressed: true,
                                guard_strategy: 'none', filter: filter)
          ev.roles = roles   # Fluxx validates the roles list itself; the role links are created on save
          e['from_states'].each { |from| ev.machine_event_from_states.build(from_state_id: states.fetch(from).id) }
          ev.save!
        end
        log << "button #{e['button_name']}: created"
      rescue => err
        log << "button #{e['button_name']}: not created (#{err.class}: #{err.message})"
      end
    end

    # The theme's After Create block finishes setup on the first save
    if theme
      after_create = fetch.call('deploy/installer/theme/After Create.rb')
      if same.call(theme.unsafe_after_create_block, after_create)
        log << "theme After Create: up to date"
      else
        theme.unsafe_after_create_block = after_create
        theme.save!
        log << "theme After Create: updated"
      end
    end

    # 6. Record values and the instance-specific dropdowns. The repo is also
    # kept in a small method, because fields can't always be set on the very
    # first record.
    settings_body = "{ 'repo_url' => #{repo_url.to_s.inspect}, 'repo_ref' => #{repo_ref.to_s.inspect} }"
    rs = ModelMethod.where(model_type: mt, name: 'PDC Repo Settings', deleted_at: nil).first
    if rs.nil?
      ModelMethod.create!(model_type: mt, method_type: 'method', name: 'PDC Repo Settings', unsafe_dyn_method: settings_body)
    elsif rs.unsafe_dyn_method.to_s.strip != settings_body
      rs.unsafe_dyn_method = settings_body
      rs.save!
    end
    model.repo_url = repo_url if model.respond_to?(:repo_url=) && model.repo_url.blank?
    model.repo_ref = repo_ref if model.respond_to?(:repo_ref=) && model.repo_ref.blank?
    log << model.dyn_invoke_for(:"PDC Populate Options").to_s

    { 'ok' => true }
  rescue => e
    { 'ok' => false, 'error' => "#{e.class}: #{e.message}" }
  end

# Results in the same shape as the other actions, for the form
entries = log.map do |line|
  key, status = line.to_s.split(': ', 2)
  next { 'status' => 'source', 'key' => status } if key == 'commit'
  status = case status
           when 'exists', 'up to date' then 'ok'
           when 'created', 'restored' then status
           when nil then (key = line.to_s; 'note')
           when /\Anot (found|created)/ then status
           when /updated|overwritten|roles? set|starts in/ then 'overwrote'
           when /\Aremoved/ then 'removed'
           else 'note'
           end
  { 'status' => status, 'key' => key }
end
record =
  begin
    boot_lib = model.dyn_invoke_for(:"PDC Installer Lib")
    # Choices on this record that no longer fit (e.g. a role deleted from Fluxx)
    warnings = (boot_lib[:choice_warnings].call(model, nil) rescue [])
    extra = result['error'] ? { 'error' => result['error'] } : {}
    extra['warnings'] = warnings if warnings.any?
    boot_lib[:results_record].call('Installer update', "from #{source_label.call}", entries, extra)
  rescue => e
    { 'title' => 'Installer update', 'mode' => "from #{source_label.call}", 'ran_at' => Time.now.utc.iso8601,
      'error' => [result['error'], "#{e.class}: #{e.message}"].compact.join(' / '),
      'groups' => [{ 'label' => 'log', 'tone' => 'info', 'items' => log.map { |l| { 'key' => l.to_s } } }] }
  end
model.installer_results = JSON.generate(record) if model.respond_to?(:installer_results=)
# Which commit the installer was last updated to (only when it worked)
if result['ok'] && model.respond_to?(:installer_commit=)
  model.installer_commit = commit
end
# Save the results and starting state, once (the flag stops this save from
# leading to another). From After Create the record is saved already; from
# Before New it's the record Fluxx made for the New form, which Fluxx would
# otherwise save only with the fields that are on the form.
if %w[after_create before_new].include?(handoff['phase']) && model.persisted? && !model.instance_variable_get(:@pdc_results_saved)
  model.instance_variable_set(:@pdc_results_saved, true)
  begin
    model.save!
  rescue => e
    nil
  end
end
JSON.generate(record)
