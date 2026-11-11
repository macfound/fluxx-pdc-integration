# PDC deploy model: After Create
#
# Written into the deploy model theme's After Create block by PDC Bootstrap
# Deploy Model; edit it here, not in Fluxx. Before New set the deploy model up
# when the first New form opened, but the buttons need the Installer Role the
# admin picks on that form (a required field). Once the record is saved, this
# runs the bootstrap again; it finds everything else in place and creates the
# buttons with that role.

#
# Loop guard: the bootstrap saves this record once to keep its results. That
# save must not run this block again, so it runs at most once per record per
# request, and only while the buttons still lack a role.

# Only one deploy record: if Before New's removal of a second record didn't
# stop the save, this record is removed here and nothing else runs.
# (Temporary records from cancelled New forms don't count.)
others = model.class.where(deleted_at: nil).where.not(id: model.id)
others = others.where(is_temp_precreate: [false, nil]) if model.class.column_names.include?('is_temp_precreate')
second_record = others.exists?
model.delete if second_record

already = second_record || model.instance_variable_get(:@pdc_after_create_ran)
needs_buttons = lambda do
  theme = ModelTheme.where(model_type: model.class.name, deleted_at: nil).order(:id).first
  wf = theme && MachineWorkflow.where(model_theme_id: theme.id, deleted_at: nil).first
  events = wf ? MachineEvent.where(machine_workflow_id: wf.id, deleted_at: nil).pluck(:id) : []
  events.empty? || events.any? { |id| !MachineEventRole.where(machine_event_id: id).exists? }
end
if !already && needs_buttons.call &&
   ModelMethod.where(model_type: model.class.name, name: 'PDC Bootstrap Deploy Model', deleted_at: nil).exists?
  model.instance_variable_set(:@pdc_after_create_ran, true)
  model.instance_variable_set(:@pdc_bootstrap, { 'phase' => 'after_create' })
  model.dyn_invoke_for(:"PDC Bootstrap Deploy Model")
end
