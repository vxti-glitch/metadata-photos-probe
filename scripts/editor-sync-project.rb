#!/usr/bin/env ruby
# Canonical engine stays in the root Swift package; never copy engine sources.
require 'pathname'
require 'xcodeproj'

root = Pathname.new(__dir__).parent
ios = root.join('editor/ios')
project = Xcodeproj::Project.open(ios.join('Runner.xcodeproj'))
runner = project.targets.find { |target| target.name == 'Runner' }
tests = project.targets.find { |target| target.name == 'RunnerTests' }
abort 'Missing expected Flutter app or test target.' unless runner && tests

package_class = Xcodeproj::Project::Object::XCLocalSwiftPackageReference
package = project.root_object.package_references.find do |reference|
  reference.is_a?(package_class) && reference.relative_path == '../..'
end
unless package
  package = project.new(package_class)
  package.relative_path = '../..'
  project.root_object.package_references << package
end

[[runner, 'Runner'], [tests, 'RunnerTests']].each do |target, directory|
  group = project.main_group.groups.find { |entry| entry.path == directory }
  abort "Missing #{directory} source group." unless group
  Dir.glob(ios.join(directory, '**/*.swift').to_s).sort.each do |path|
    relative = Pathname.new(path).relative_path_from(ios.join(directory)).to_s
    reference = group.files.find { |entry| entry.path == relative } || group.new_file(relative)
    unless target.source_build_phase.files_references.include?(reference)
      target.source_build_phase.add_file_reference(reference)
    end
  end
  dependency = target.package_product_dependencies.find { |entry| entry.product_name == 'ProbeCore' }
  unless dependency
    dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
    dependency.package = package
    dependency.product_name = 'ProbeCore'
    target.package_product_dependencies << dependency
  end
  unless target.frameworks_build_phase.files.any? { |entry| entry.product_ref == dependency }
    build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
    build_file.product_ref = dependency
    target.frameworks_build_phase.files << build_file
  end
  target.build_configurations.each do |configuration|
    configuration.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
    configuration.build_settings['SWIFT_VERSION'] = '5.0'
    configuration.build_settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
    configuration.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = directory == 'Runner' ?
      'com.vxtiglitch.metadataeditor' : 'com.vxtiglitch.metadataeditor.RunnerTests'
  end
end
project.build_configurations.each do |configuration|
  configuration.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
end
project.save
puts "Synced #{runner.source_build_phase.files.count} app sources and #{tests.source_build_phase.files.count} test sources."
puts "ProbeCore resolved from #{ios.join('../..').cleanpath}, xcodeproj #{Xcodeproj::VERSION}."
