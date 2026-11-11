# PDC Keep Deploy Record (after_destroy)
#
# The deploy record holds the installer's results and the pointers Restore
# Previous needs, and Before New only sets PDC up on the first record. A GUI
# delete is a soft delete, so if this was the only live deploy record, it is
# undeleted straight away. (Before New's own removal of a second record uses
# delete, which doesn't run this.) To remove PDC entirely, run Uninstall and
# then delete the deploy model itself.

others = model.class.unscoped.where(deleted_at: nil).where.not(id: model.id)
others = others.where(is_temp_precreate: [false, nil]) if model.class.column_names.include?('is_temp_precreate')
unless others.exists?
  model.class.unscoped.where(id: model.id).update_all(deleted_at: nil)
  model.deleted_at = nil if model.respond_to?(:deleted_at=)
end
