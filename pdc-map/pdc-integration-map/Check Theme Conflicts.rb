# Check Theme Conflicts (before_save on the PDC Integration Map)
# A grant finds its map by theme, so an active map can't share a Grant Request
# Theme with another active map. Stops the save (on Activate, or when an active
# map's themes are edited) and names the maps and themes involved.

if model.state.to_s == 'active'
  mine = model.dyn_invoke_for(:"Get Grant Request Theme Ids")
  clashes = model.class.where(state: 'active', deleted_at: nil).where.not(id: model.id).map do |other|
    shared = other.dyn_invoke_for(:"Get Grant Request Theme Ids") & mine
    next if shared.empty?
    names = shared.map { |id| ModelTheme.find_by(id: id.to_i)&.name || "theme #{id}" }
    "#{other.get_dyn_value(:name).presence || "map #{other.id}"} (#{names.join(', ')})"
  end.compact
  unless clashes.empty?
    raise "Another active PDC Integration Map already uses these Grant Request Themes: #{clashes.join('; ')}. " \
          "Each theme can be on one active map only."
  end
end
