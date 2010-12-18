require 'rubygems'
require 'em-dns-server'
require 'sinatra/base'
require 'builder'
require 'hmac'
require 'hmac-sha2'
require 'base64'
require 'rexml/document'
require 'haml'
require File.join(File.dirname(__FILE__), 'helpers')
require File.join(File.dirname(__FILE__), 'uuid')
require File.join(File.dirname(__FILE__), 'errors')
require File.join(File.dirname(__FILE__), 'admin')

module Route53

class WebAPI < Sinatra::Base

  PLUGIN_PATH = File.join(File.dirname(__FILE__),'..')

  disable :raise_errors, :show_exception
  set :environment, :production

  def self.config
    @@config ||= {}
  end

  helpers do
    include Route53::Helpers
  end
  
  configure do
    @@config = YAML::load(File.read(File.join(File.dirname(__FILE__),'../route53.yml')))
    Dir.entries(DNSServer::ZONE_FILES).each do |file|
      if file =~ /^(.*).zone$/
        DNSServer.load_zone(File.join(DNSServer::ZONE_FILES, file))
      end
    end
  end

  before do
    @request_id = UUID.create
    @current_date = Time.now.getgm.httpdate
    headers 'x-amz-request-id' => @request_id.to_s
    headers 'Date' => @current_date.to_s

    raise MissingAuthenticationToken unless env.has_key?('AWS_AUTH_USER')
    @user = env['AWS_AUTH_USER']
  end

  get "/hostedzone" do
    max_items = (params[:maxitems] || 100).to_i
    max_items = 100 if max_items <= 0 || max_items > 100
    marker = params[:marker]

    z, next_marker = zones(max_items,marker)

    xml do |x|
      x.ListHostedZonesResponse :xmlns => "https://route53.amazonaws.com/doc/2010-10-01/" do
        x.HostedZones do
          z.each do |origin,zone|
            x.HostedZone do
              x.Id "/hostedzone/#{zone.key}"
              x.Name origin
              x.CallerReference zone.ref
              x.Config do
                x.Comment zone.comment
              end
            end
          end
        end
        x.MaxItems max_items
        x.IsTruncated next_marker.nil? ? false : true
        x.NextMarker next_marker
      end
    end
  end

  get %r{\/hostedzone\/([\w]+)$} do
    zone_id = params[:captures].first
    z, zone_data = get_zone_by_key(zone_id)

    xml do |x|
      x.GetHostedZoneResponse :xmlns => "https://route53.amazonaws.com/doc/2010-10-01/" do
        x.HostedZone do
          x.Id "/hostedzone/#{zone_id}"
          x.Name z
          x.CallerReference zone_data.ref
          x.Config do
            x.Comment zone_data.comment
          end
        end
        x.DelegationSet do
          x.NameServers do
            zone_data.records.each do |record|
              x.NameServer record.full_address if record.full_name == z && record.type == "NS"
            end
          end
        end
      end
    end
  end

  post "/hostedzone" do
    env['rack.input'].rewind
    data = env['rack.input'].read
    xml_request = REXML::Document.new(data).root
    z = xml_request.elements["Name"].text
    ref = xml_request.elements["CallerReference"].text
    comment = xml_request.elements["HostedZoneConfig/Comment"].text

    begin
      get_zone(z)
      raise HostedZoneAlreadyExists
    rescue AccessDenied
      # domain does not exist, continue
    end
    raise InvalidDomainName if z[-1,1] != "."

    change_id = create_zone(z,ref,comment)
    zone_data = get_zone(z)

    xml do |x|
      x.CreateHostedZoneResponse :xmlns => "https://route53.amazonaws.com/doc/2010-10-01/" do
        x.HostedZone do
          x.Id "/hostedzone/#{zone_data.key}"
          x.Name z
          x.CallerReference ref
          x.Config do
            x.Comment comment
          end
        end
        x.ChangeInfo do
          x.Id "/change/#{change_id}"
          x.Status "PENDING"
          x.SubmittedAt Time.now.getgm.iso8601
        end
        x.DelegationSet do
          x.NameServers do
            zone_data.records.each do |record|
              x.NameServer record.full_address if record.full_name == z && record.type == "NS"
            end
          end
        end
      end
    end
  end

  delete %r{\/hostedzone\/([\w]+)$} do
    zone_id = params[:captures].first
    z, zone_data = get_zone_by_key(zone_id)
    change_id = delete_zone(z)

    xml do |x|
      x.DeleteHostedZoneResponse :xmlns => "https://route53.amazonaws.com/doc/2010-10-01/" do
        x.ChangeInfo do
          x.Id "/change/#{change_id}"
          x.Status "PENDING"
          x.SubmittedAt Time.now.getgm.iso8601
        end
      end
    end
  end

  post %r{\/hostedzone\/([\w]+)\/rrset$} do
    zone_id = params[:captures].first
    z, zone_data = get_zone_by_key(zone_id)
    env['rack.input'].rewind
    data = env['rack.input'].read
    xml_request = REXML::Document.new(data).root

    xml_request.each_element('//ChangeResourceRecordSetsRequest/ChangeBatch/Changes/Change') do |element|
      action = element.elements["Action"].text
      name = element.elements["ResourceRecordSet/Name"].text
      type = element.elements["ResourceRecordSet/Type"].text
      ttl = element.elements["ResourceRecordSet/TTL"].text
      element.each_element('ResourceRecordSet/ResourceRecords/ResourceRecord/Value') do |addy|
        case action.upcase
        when "DELETE"
          delete_record(z, name, type, addy.text)
        when "CREATE"
          create_record(z, name, type, ttl, addy.text)
        end
      end
    end

    change_id = record_change(z, "ChangeResourceRecordSets", data)

    xml do |x|
      x.ChangeResourceRecordSetsResponse :xmlns => "https://route53.amazonaws.com/doc/2010-10-01/" do
        x.ChangeInfo do
          x.Id "/change/#{change_id}"
          x.Status "PENDING"
          x.SubmittedAt Time.now.getgm.iso8601
        end
      end
    end
  end

  get %r{\/hostedzone\/([\w]+)\/rrset$} do
    zone_id = params[:captures].first
    z, zone_data = get_zone_by_key(zone_id)
    max_items = (params[:maxitems] || 100).to_i
    type = params[:type]
    name = params[:name]

    records, next_marker = zone_records(zone_data.records,name,type,max_items)

    xml do |x|
      x.ListResourceRecordSetsResponse :xmlns => "https://route53.amazonaws.com/doc/2010-10-01/" do
        records.each do |key,value|
          x.ResourceRecordSets do
            x.ResourceRecordSet do
              x.Name value[:record].full_name
              x.Type value[:record].type
              x.TTL value[:record].ttl
              x.ResourceRecords do |bla|
                value[:addresses].each do |address|
                  x.ResourceRecord do
                    case value[:record].type
                    when "SOA"
                      x.Value "#{value[:record].ns} #{value[:record].email} #{value[:record].address.join(' ')}"
                    when "MX"
                      x.Value "#{value[:record].priority} #{expanded_address(address,z)}"
                    else
                      x.Value expanded_address(address,z)
                    end
                  end
                end
              end
            end
          end
        end
        x.IsTruncated next_marker.nil? ? false : true
        x.MaxItems max_items
        x.NextRecordName expanded_address(next_marker[:name],z) unless next_marker.nil?
        x.NextRecordType next_marker[:type] unless next_marker.nil?
      end
    end
  end

  get %r{\/change\/([\w]+)$} do
    change_id = params[:captures].first
    change = get_change(change_id)

    xml do |x|
      x.GetChangeResponse :xmlns => "https://route53.amazonaws.com/doc/2010-10-01/" do
        x.ChangeInfo do
          x.Id "/change/#{change_id}"
          x.Status "INSYNC"
          x.SubmittedAt change[:time]
        end
      end
    end
  end

  error do
    error = Builder::XmlMarkup.new
    error.instruct! :xml, :version=>"1.0", :encoding=>"UTF-8"

    error.ErrorResponse :xmlns => "https://route53.amazonaws.com/doc/2010-10-01/" do
      error.Error do
        error.Type "Sender"
        error.Code request.env['sinatra.error'].code
        error.Message request.env['sinatra.error'].message
      end
      error.RequestId @request_id
    end

    status request.env['sinatra.error'].status.nil? ? 500 : request.env['sinatra.error'].status
    content_type 'application/xml'
    body error.target!
  end

  protected

  def xml
    xml = Builder::XmlMarkup.new
    xml.instruct! :xml, :version=>"1.0", :encoding=>"UTF-8"
    yield xml
    content_type 'application/xml'
    xml.target!
  end

end
end
