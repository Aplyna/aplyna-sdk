require 'json'
package = JSON.parse(File.read(File.join(__dir__, 'package.json')))
Pod::Spec.new do |s|
  s.name = 'AplynaReactNative'
  s.module_name = 'AplynaReactNative'
  s.version = package['version']
  s.summary = package['description']
  s.homepage = 'https://aplyna.com'
  s.license = { :type => 'Proprietary' }
  s.author = { 'Aplyna' => 'support@aplyna.com' }
  s.source = { :git => 'https://github.com/Forcrazyx/aplyna.git' }
  s.platform = :ios, '16.0'
  s.swift_version = '5.0'
  s.source_files = 'ios/**/*.{h,m,mm,swift}'
  s.frameworks = 'StoreKit', 'Security', 'SwiftUI', 'AppTrackingTransparency'
  install_modules_dependencies(s)
end
