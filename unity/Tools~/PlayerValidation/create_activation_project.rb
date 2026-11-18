require 'xcodeproj'
require 'fileutils'

root = File.expand_path(ARGV.fetch(0))
FileUtils.mkdir_p(root)
FileUtils.cp(File.join(__dir__, 'ForegroundTests.m'), root)
project = Xcodeproj::Project.new(File.join(root, 'Activate.xcodeproj'))
target = project.new_target(:ui_test_bundle, 'GamePropelActivationTests', :ios, '15.0')
target.source_build_phase.add_file_reference(project.main_group.new_file('ForegroundTests.m'))
target.build_configurations.each do |config|
  config.build_settings.merge!({
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.gamepropel.unityactivationtests',
    'GENERATE_INFOPLIST_FILE' => 'YES',
    'CODE_SIGNING_ALLOWED' => 'NO',
    'SDKROOT' => 'iphonesimulator',
    'SUPPORTED_PLATFORMS' => 'iphonesimulator',
    'TARGETED_DEVICE_FAMILY' => '1,2',
    'CLANG_ENABLE_MODULES' => 'YES',
    'FRAMEWORK_SEARCH_PATHS' => ['$(inherited)', '$(PLATFORM_DIR)/Developer/Library/Frameworks'],
    'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks', '@loader_path/Frameworks'],
  })
end
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.add_test_target(target)
project.save
scheme.save_as(project.path, 'Activate')
