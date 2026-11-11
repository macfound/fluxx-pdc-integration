# PDC deploy model: Before New
#
# The ONLY thing an admin pastes by hand (into the deploy model theme's
# Before New block). When the first New form opens, it downloads PDC Bootstrap
# Deploy Model from the repo and runs it: that builds the deploy model's
# fields, dropdowns, methods, states and form, and writes the theme's After
# Create block. The admin picks the required Installer Role and saves; After
# Create then creates the buttons with that role.
# Only one deploy record may exist: a second one deletes itself (Fluxx shows
# an error page; raising an error here does NOT stop the save). Fluxx has
# already created a temporary record by the time this runs.
#
# repo_url / repo_ref: where the installer reads from. Whatever is at that ref
# becomes Ruby that runs in this Fluxx instance (see Advanced configuration in
# deploy/README.md).

require 'json'
require 'net/http'
require 'uri'
require 'cgi'

repo_url = "https://github.com/macfound/fluxx-pdc-integration"
repo_ref = "main"

# Fluxx creates a temporary record when New is clicked (and keeps it as the
# real one on save), so this record already exists here, and cancelled New
# forms leave temporary records behind: only real records count.
others = model.class.where(deleted_at: nil).where.not(id: model.id)
others = others.where(is_temp_precreate: [false, nil]) if model.class.column_names.include?('is_temp_precreate')

# Until the installer is set up (its bootstrap method exists), earlier records
# are leftovers of attempts that failed (e.g. the repo couldn't be reached)
# and hold only the error: they're soft-deleted so a retry just works.
installer_set_up = ModelMethod.where(model_type: model.class.name, name: 'PDC Bootstrap Deploy Model', deleted_at: nil).exists?
if others.exists? && !installer_set_up
  others.each do |old|
    old.deleted_at = Time.now
    old.save!(validate: false) rescue nil
  end
end

if others.exists? && installer_set_up
  model.delete
else
  path = "deploy/installer/PDC Bootstrap Deploy Model.rb"
  # A raise here is silently ignored and the record saves anyway, so a failure
  # is written where it can always be seen: a "PDC Installer Log" method on
  # this model (creating methods always works here), and the installer_results
  # field (created if needed). The record Fluxx made for this New form isn't
  # saved by Fluxx except for the fields on the form, so it's saved here. If
  # the field can't be written, the record is deleted rather than left looking
  # set up.
  fail_with = lambda do |msg|
    begin
      body = "# #{Time.now.utc} #{msg.to_s.gsub("\n", ' ')}\nnil"
      log_method = ModelMethod.where(model_type: model.class.name, name: 'PDC Installer Log', deleted_at: nil).first
      log_method ? log_method.update_columns(unsafe_dyn_method: body) :
                   ModelMethod.create!(model_type: model.class.name, method_type: 'method', name: 'PDC Installer Log', unsafe_dyn_method: body)
    rescue => e
      nil
    end
    unless model.respond_to?(:installer_results=)
      begin
        unless ModelAttribute.where(model_type: model.class.name, name: 'installer_results', deleted_at: nil).exists?
          ModelAttribute.create!(model_type: model.class.name, name: 'installer_results', attribute_type: 'text',
                                 multi_allowed: false, description: 'Installer Results')
        end
      rescue => e
        nil
      end
    end
    if model.respond_to?(:installer_results=)
      model.installer_results = JSON.generate('title' => 'Installer update', 'mode' => 'failed', 'error' => msg)
      begin
        model.save! if model.persisted?
      rescue => e
        nil
      end
    else
      model.delete
    end
    msg
  end
  begin
    m = repo_url.to_s.strip.match(%r{github\.com[/:]([^/]+)/([^/]+?)(?:\.git)?/?\z})
    raise "repo_url must be a github.com repository URL, got #{repo_url.inspect}" unless m
    uri = URI.parse("https://raw.githubusercontent.com/#{m[1]}/#{m[2]}/#{repo_ref}/#{path.split('/').map { |p| CGI.escape(p).gsub('+', '%20') }.join('/')}")
    resp = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
      http.request(Net::HTTP::Get.new(uri))
    end
    if resp.code == '200'
      body = resp.body.to_s.dup.force_encoding('UTF-8')
      bootstrap = ModelMethod.where(model_type: model.class.name, name: 'PDC Bootstrap Deploy Model', deleted_at: nil).first
      if bootstrap
        bootstrap.unsafe_dyn_method = body
        bootstrap.save!
      else
        ModelMethod.create!(model_type: model.class.name, method_type: 'method', name: 'PDC Bootstrap Deploy Model', unsafe_dyn_method: body)
      end
      model.instance_variable_set(:@pdc_bootstrap, { 'repo_url' => repo_url, 'repo_ref' => repo_ref, 'phase' => 'before_new' })
      out = model.dyn_invoke_for(:"PDC Bootstrap Deploy Model")
      res = (JSON.parse(out.to_s) rescue nil)
      # The bootstrap writes its own results (with the error, if any) to
      # installer_results; if that field couldn't be set, don't keep the record
      model.delete if res && res['error'] && !model.respond_to?(:installer_results=)
      out
    else
      fail_with.call("PDC bootstrap: could not fetch #{path} at #{repo_ref} (HTTP #{resp.code})")
    end
  rescue => e
    fail_with.call("PDC bootstrap failed: #{e.class}: #{e.message}")
  end
end
