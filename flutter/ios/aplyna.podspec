Pod::Spec.new do |s|
  s.name = 'aplyna'
  s.version = '1.0.0'
  s.summary = 'Aplyna native events, assignments and remote configuration.'
  s.description = s.summary
  s.homepage = 'https://aplyna.com'
  s.license = { :type => 'Proprietary' }
  s.author = { 'Aplyna' => 'support@aplyna.com' }
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*.swift'
  s.dependency 'Flutter'
  s.platform = :ios, '16.0'
  s.swift_version = '5.0'
  s.frameworks = 'StoreKit', 'Security', 'SwiftUI', 'AppTrackingTransparency'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
