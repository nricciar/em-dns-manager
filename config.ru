$:.unshift "./lib"
ENV['ZONE_FILES'] ||= File.join(File.dirname(__FILE__), 'zones')
ENV['AWS_AUTH_PATH'] ||= File.expand_path(File.join(File.dirname(__FILE__),'route53.yml'))
require 'rubygems'
require 'aws-auth'
require 'api'

AWS::Admin.home_page = "/control/dns"

# AWS Base
use AWSAuth::Base
map '/control' do
  run AWS::Admin
end

# Route53
map '/2010-10-01' do
  run Route53::WebAPI
end

# S3 Support (un-comment if wanted)
#require 'sinatra-s3'
#map '/' do
#  use S3::Tracker if defined?(RubyTorrent)
#  run S3::Application
#end
