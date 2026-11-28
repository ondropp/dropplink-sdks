Pod::Spec.new do |s|
  s.name             = 'Dropplink'
  s.version          = '0.2.1'
  s.summary          = 'Install attribution, deferred deep links and in-app events for apps using Dropplink links.'
  s.description      = <<-DESC
    Dropplink attributes app installs to the Dropplink link that drove them, delivers deferred deep links
    after a fresh install, resolves Universal Link opens and sends in-app events and user identify
    through an offline-safe queue. No third-party dependencies.
  DESC
  s.homepage         = 'https://ondropp.app'
  s.license          = { :type => 'Proprietary', :text => 'Copyright Dropp Services Private Limited. All rights reserved.' }
  s.author           = { 'Dropplink' => 'sdk@ondropp.app' }
  # The tag is the shared release tag (docs/releasing.md).
  s.source           = { :git => 'https://github.com/ondropp/dropplink-sdks.git', :tag => "v#{s.version}" }

  s.ios.deployment_target = '13.0'
  s.swift_versions   = ['5.9', '6.0']
  s.frameworks       = 'Foundation', 'CryptoKit', 'UIKit'

  # Paths are relative to this file (ios/), which is what `pod lib lint` and `:path =>` installs use.
  s.source_files     = 'Sources/Dropplink/**/*.swift'
  s.resource_bundles = { 'Dropplink_Privacy' => ['Sources/Dropplink/PrivacyInfo.xcprivacy'] }
end
