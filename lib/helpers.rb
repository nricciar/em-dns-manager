module Route53
  module Helpers

  def zones(max_items,marker)
    ret = {}
    count = 0
    next_marker = nil

    DNSServer.zonemap.each do |key,value|
      if count == max_items
        next_marker = value.key
        break
      else
        if marker.nil? && value.uid.to_i == @user.id
          ret[key] = value
          count += 1
        else
          ret[key] = value and count += 1 if (ret.length > 0 || value.key == marker) && value.uid.to_i == @user.id
        end
      end
    end
    [ ret, next_marker ]
  end

  def get_zone(zone)
    DNSServer.zonemap[zone] || raise(Route53::AccessDenied)
  end

  def get_zone_by_key(zone_id)
    DNSServer.zonemap.each do |key,value|
      return [ key, value ] if value.key == zone_id && value.uid.to_i == @user.id
    end
    raise Route53::AccessDenied
  end

  def zone_records(records,name,type,max_items)
    ret = {}
    count = 0
    next_marker = nil
    records.sort! { |x,y| "#{x.name}#{x.type}" <=> "#{x.name}#{x.type}" }

    records.each do |record|
      if count == max_items
        next_marker = record
        break
      else
        if type.nil?
          if type.nil? || type == record.type
            ret["#{record.name}:#{record.type}"] ||= { :record => record, :addresses => [] }
            ret["#{record.name}:#{record.type}"][:addresses] << record.address
            count += 1
          end
        else
          if record.type == type && name == record.name

          end
        end
      end
    end
    [ ret, next_marker ]
  rescue
    raise Route53::InternalError
  end

  def get_change(change_id)
    dir = File.join(DNSServer::ZONE_FILES,"changes")
    file = File.join(dir, change_id)
    if File.exists?(file)
      YAML::load(File.read(file))
    else
      raise Route53::AccessDenied
    end
  end

  def record_change(zone, change_type, data)
    dir = File.join(DNSServer::ZONE_FILES,"changes")
    FileUtils.mkdir_p(dir) unless File.exists?(dir)
    change_id = AWSAuth::Base.generate_key
    file = File.join(dir, change_id)
    File.open(file, "w") { |f| f.write(YAML::dump({ :zone => zone, :change_type => change_type,
          :data => data, :time => Time.now.getgm.iso8601 })) }
    change_id
  rescue
    raise Route53::InternalError
  end

  def create_zone(zone,ref,comment)
    raise Route53::InvalidInput if zone !~ /^([-\w\d]+((\.[-\w\d]+)*)?\.?)\.$/
    raise Route53::InvalidInput if ref !~ /^(\w+)$/

    filename = File.join(DNSServer::ZONE_FILES, "#{zone}zone")
    zone_id = AWSAuth::Base.generate_key
    ttl = Route53::WebAPI.config[:ttl] || 86400
    primary_ns = Route53::WebAPI.config[:nameservers][rand(Route53::WebAPI.config[:nameservers].size)]
    zone_file = <<EOS
;$REF #{ref}
;$ZONEID #{zone_id} ; #{comment}
;$UID #{@user.id}
$TTL    #{ttl}
$ORIGIN #{zone}
@  1D  IN        SOA #{primary_ns}   root.#{zone} (
                              #{Time.now.strftime('%Y%m%d')}01 ; serial
                              #{Route53::WebAPI.config[:refresh]} ; refresh
                              #{Route53::WebAPI.config[:retry]} ; retry
                              #{Route53::WebAPI.config[:expire]} ; expire
                              #{Route53::WebAPI.config[:minimum]} ; minimum
                             )
EOS
    Route53::WebAPI.config[:nameservers].each { |ns| zone_file << "@      IN  NS     #{ns}\n" }
    File.open(filename,'w') { |f| f.write(zone_file) }
    change_id = record_change(zone, "CreateHostedZone", { :ref => ref, :comment => comment })
    zone = DNSServer::ZoneFile.new(filename)
    DNSServer.zonemap[zone.origin] = zone
    change_id
  end

  def delete_zone(zone)
    zone = DNSServer.zonemap[zone]

    dir = File.join(DNSServer::ZONE_FILES,"deleted")
    FileUtils.mkdir_p(dir) unless File.exists?(dir)

    FileUtils.mv zone.filename, dir
    DNSServer.zonemap.delete(zone.origin)
    record_change(zone.origin, "DeleteHostedZone", nil)
  rescue
    raise Route53::InternalError
  end

  def delete_record(zone, name, type, address)
    zone = DNSServer.zonemap[zone]
    raise Route53::InternalError if zone.nil?

    zone.records.delete_if { |r| r.full_name == expanded_address(name,zone.origin) && r.type == type && r.full_address == expanded_address(address,zone.origin) }
    zone.save()
  end

  def create_record(zone, name, type, ttl, address)
    priority = nil
    name.sub!($3,"") if name =~ /((.*)((\A|.)#{zone}))$/
    name = "@" if name == ""

    if type == "MX" && address =~ /^(\d+)\s+(.*)$/
      priority = $1
      address = $2
    end

    address.sub!($3,"") if address =~ /((.*)((\A|.)#{zone}))$/
    address = "@" if address == ""

    zone = DNSServer.zonemap[zone]
    raise Route53::InternalError if zone.nil?

    record = { :name => name, :type => type, :class => "IN", :ttl => ttl, :address => address }
    record.merge({ :priority => priority }) unless priority.nil?

    zone.add_record(record)
    zone.save()
  end

  def expanded_address(address,zone)
    return address if address =~ /^\d+\.\d+\.\d+\.\d+$/
    return zone if address == "@"
    return "#{address}.#{zone}" if address[-1,1] != "."
    address
  end

  end
end
