Pod::Spec.new do |s|
  s.name             = 'Dropplink'
  s.version          = '0.1.0'
  s.summary          = 'Install attribution and deferred deep links for apps using Dropp links.'
  s.description      = <<-DESC
    Dropplink attributes app installs to the Dropp link that drove them, delivers deferred deep links
    after a fresh install and resolves Universal Link opens. No third-party dependencies.
  DESC
  s.homepage         = 'https://ondropp.app'
  s.license          = { :type => 'Proprietary', :text => 'Copyright Dropp. All rights reserved.' }
  s.author           = { 'Dropp' => 'sdk@ondropp.app' }
  # Placeholder: the real repository URL and tag are set at release time (docs/releasing.md).
  s.source           = { :git => 'https://github.com/ondropp/dropplink-sdks.git', :tag => "ios-v#{s.version}" }

  s.ios.deployment_target = '13.0'
  s.swift_versions   = ['5.9', '6.0']
  s.frameworks       = 'Foundation', 'CryptoKit', 'UIKit'

  # Paths are relative to this file (ios/), which is what `pod lib lint` and `:path =>` installs use.
  s.source_files     = 'Sources/Dropplink/**/*.swift'
  s.resource_bundles = { 'Dropplink_Privacy' => ['Sources/Dropplink/PrivacyInfo.xcprivacy'] }
end
