# PDC Get Integration Mapping
# The active PDC Integration Map whose Grant Request Themes include this grant's
# theme, or nil if there is none. Raises if more than one active map has the
# theme (the map's Check Theme Conflicts normally prevents that).

theme_id = model.model_theme_id.to_s
maps = MacModelTypeDynPdcApplicationForm1.where(state: 'active', deleted_at: nil).select do |map|
  map.dyn_invoke_for(:"Get Grant Request Theme Ids").include?(theme_id)
end
if maps.size > 1
  raise "More than one active PDC Integration Map has this grant's theme: " +
        maps.map { |m| m.get_dyn_value(:name).presence || "map #{m.id}" }.join(', ')
end
maps.first
