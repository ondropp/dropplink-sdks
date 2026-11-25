#
# Flutter bridge to the native Dropplink iOS SDK (pod 'Dropplink').
# Run `pod lib lint dropplink_flutter.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'dropplink_flutter'
  s.version          = '0.2.0'
  s.summary          = 'Dropplink install attribution, deep linking and in-app events for Flutter.'
  s.description      = <<-DESC
Flutter plugin for Dropplink. A thin bridge: all logic lives in the native Dropplink iOS SDK.
                       DESC
  s.homepage         = 'https://ondropp.app'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'Dropplink'
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.dependency 'Dropplink', '0.2.0'
  s.platform         = :ios, '13.0'

  # Flutter.framework does not contain an i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version    = '5.0'

  s.resource_bundles = { 'dropplink_privacy' => ['Resources/PrivacyInfo.xcprivacy'] }
end
