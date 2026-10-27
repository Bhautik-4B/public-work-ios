# Switches only the app target to manual signing with the given profile, so
# Pods and other targets keep their own settings.
# Usage: ruby manual_signing.rb <project.xcodeproj> <target> <configuration> <team> <profile name> <profile uuid>
require "xcodeproj"

path, target_name, config, team, profile_name, profile_uuid = ARGV
project = Xcodeproj::Project.open(path)
target = project.targets.find { |t| t.name == target_name } or abort("Target not found - set the IOS_SCHEME secret")

target.build_configurations.select { |c| c.name == config }.each do |c|
  s = c.build_settings
  s["CODE_SIGN_STYLE"] = "Manual"
  s["DEVELOPMENT_TEAM"] = team
  s["CODE_SIGN_IDENTITY"] = "Apple Distribution"
  s["CODE_SIGN_IDENTITY[sdk=iphoneos*]"] = "Apple Distribution"
  s["PROVISIONING_PROFILE_SPECIFIER"] = profile_name
  s["PROVISIONING_PROFILE"] = profile_uuid
end

attrs = project.root_object.attributes["TargetAttributes"]
attrs[target.uuid]["ProvisioningStyle"] = "Manual" if attrs && attrs[target.uuid]
project.save
puts "Manual signing set on the app target"
