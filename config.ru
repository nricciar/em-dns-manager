$:.unshift "./lib"
ENV['ZONE_FILES'] = File.join(File.dirname(__FILE__), 'zones')
require 'rubygems'
require 'aws-auth'
require 'api'

AWS::Admin.home_page = "/control/dns"

# AWS Base
use AWSAuth::Base, File.expand_path(File.join(File.dirname(__FILE__),'route53.yml'))
map '/control' do
  run AWS::Admin
end

# Route53
map '/2010-10-01' do
  run Route53::WebAPI
end
