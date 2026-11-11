# Reset PDC Dropdown Values (cascade, guarded)
#
# model_attribute_choices_table holds saved field values, not picklist
# definitions. Deleting a row there blanks that field on the owning record.
# The guard below refuses to run if any owner record is still live.
#
# In PROD, data does not promote, so the child table is likely empty and the
# simple ModelAttributeValue delete_all will succeed on its own. Check first.
#
# After this runs clean, re-run:
#   Set PDC Field Model Values
#   Set Application Dropdown Values
#   Set Opportunity Dropdown Values

dry_run             = true
abort_if_live_owner = true   # leave true unless you have a reason

conn = ActiveRecord::Base.connection

# attribute id => model that owns records carrying it
attr_owners = {
  306883 => "MacModelTypeDynPdcMappedField1",     # pdc_field
  307386 => "MacModelTypeDynPdcApplicationForm1", # application
  306879 => "MacModelTypeDynPdcApplicationForm1"  # opportunity
}

report = {
  dry_run:        dry_run,
  attributes:     [],
  child_rows:     0,
  live_owners:    0,
  values_removed: 0,
  child_removed:  0,
  errors:         []
}

use_client_id = ModelAttributeValue.column_names.include?("client_id")

# --- survey ---
attr_owners.each do |attr_id, owner_class_name|
  ma = ModelAttribute.find_by(id: attr_id)
  if ma.nil?
    report[:errors] << "ModelAttribute #{attr_id} not found"
    next
  end

  value_ids = ModelAttributeValue.where(model_attribute_id: attr_id).pluck(:id)
  id_list   = value_ids.map(&:to_i).join(",")

  # Scope by model_attribute_id too. Other attributes have choice rows that
  # reference these same value ids; filtering on value id alone catches them.
  owner_ids = id_list.empty? ? [] : conn.select_values(
    "SELECT DISTINCT model_id FROM model_attribute_choices_table " \
    "WHERE model_attribute_id = #{attr_id.to_i} AND model_attribute_value_id IN (#{id_list})"
  ).map(&:to_i)

  child_count = id_list.empty? ? 0 : conn.select_value(
    "SELECT COUNT(*) FROM model_attribute_choices_table " \
    "WHERE model_attribute_id = #{attr_id.to_i} AND model_attribute_value_id IN (#{id_list})"
  ).to_i

  # Rows on OTHER attributes that would be hit by an unscoped delete.
  collateral = id_list.empty? ? 0 : conn.select_value(
    "SELECT COUNT(*) FROM model_attribute_choices_table " \
    "WHERE model_attribute_id <> #{attr_id.to_i} AND model_attribute_value_id IN (#{id_list})"
  ).to_i

  klass = owner_class_name.constantize rescue nil
  live  = if klass && owner_ids.any?
    klass.where(id: owner_ids).count   # default scope, live records only
  else
    0
  end

  report[:attributes] << {
    attribute:       ma.name,
    model_type:      ma.model_type,
    value_count:     value_ids.size,
    child_row_count: child_count,
    owner_records:   owner_ids.size,
    live_owners:     live,
    collateral_rows_on_other_attributes: collateral
  }
  report[:child_rows]  += child_count
  report[:live_owners] += live
  report[:collateral]   = report[:collateral].to_i + collateral
end

# --- guard ---
if report[:live_owners] > 0 && abort_if_live_owner
  report[:errors] << "ABORTED: #{report[:live_owners]} live owner record(s) would have a field blanked. Review before proceeding."
  dry_run = true
end

# --- delete ---
unless dry_run
  ActiveRecord::Base.transaction do
    attr_owners.each_key do |attr_id|
      # NOTE: deleting the parent value rows still trips the FK if any other
      # attribute holds a choice row against them. If report[:collateral] > 0,
      # do not run this. Resolve those attributes first.
      rows = if use_client_id
        ModelAttributeValue.where(model_attribute_id: attr_id).pluck(:id, :client_id)
      else
        ModelAttributeValue.where(model_attribute_id: attr_id).pluck(:id).map { |i| [i, nil] }
      end
      next if rows.empty?

      rows.each_slice(200) do |slice|
        clause = if use_client_id
          slice.map { |id, cid|
            cid.nil? ? "(model_attribute_value_id = #{id.to_i})"
                     : "(model_attribute_value_id = #{id.to_i} AND client_id = #{cid.to_i})"
          }.join(" OR ")
        else
          "model_attribute_value_id IN (#{slice.map { |r| r[0].to_i }.join(',')})"
        end

        # model_attribute_id filter keeps this off other attributes' data
        report[:child_removed] += conn.delete(
          "DELETE FROM model_attribute_choices_table " \
          "WHERE model_attribute_id = #{attr_id.to_i} AND (#{clause})"
        ).to_i
      end

      report[:values_removed] += ModelAttributeValue.where(model_attribute_id: attr_id).delete_all
    end
  end
end

report
