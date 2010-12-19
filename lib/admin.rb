module AWS

  class Admin < Sinatra::Base

    ALLOWED_TYPES = ['A','AAAA','CNAME','MX','NS','PTR','TXT']

    set :sessions, :on
    enable :inline_templates

    helpers do
      include Route53::Helpers
    end

    before do
      ActiveRecord::Base.verify_active_connections!
    end

    get '/dns/?' do
      login_required
      @zones, @next_marker = zones(100,params[:marker])
      r :dns, "DNS Manager"
    end

    post '/dns/?' do
      login_required
      begin
        create_zone(params[:zone],AWSAuth::Base.generate_key,'created by web admin')
        redirect '/control/dns'
      rescue Route53::InvalidInput
        @error = "<ul class=\"errors\"><li>Invalid Zone Name. Forgot the ending period?</li></ul>"
        @zones, @next_marker = zones(100,params[:marker])
        r :dns, "DNS Manager"
      end
    end

    post %r{^\/dns\/(\w+)/delete} do
      login_required
      z, @zone = get_zone_by_key(params[:captures].first)

      if params[:name] && params[:type] && params[:address]
        delete_record(z,params[:name],params[:type],params[:address])
        redirect "/control/dns/#{@zone.key}"
      else
        delete_zone(z)
        redirect '/control/dns'
      end
    end

    get %r{^\/dns\/(\w+)$} do
      login_required
      z, @zone = get_zone_by_key(params[:captures].first)
      r :zone, z[0..-2]
    end

    post %r{^\/dns\/(\w+)$} do
      login_required
      z, @zone = get_zone_by_key(params[:captures].first)

      name = params[:name]
      ttl = nil
      type = nil
      address = params[:value]
      @errors = []

      if name !~ /^(|\*|\*.[-\w\d\.]+|[-\w\d\.]+|\s*\@|\.|[-\w\d]+(((\.[-\w\d]+)*)\.?)?)$/
        @errors << "invalid name"
      end
      if address !~ /^([-\w\d]+((\.[-\w\d]+)*)?\.?)$/
        @errors << "invalid value"
      end
      if params[:ttl] =~ /^([0-9]+)$/
        ttl = $1
      else
        @errors << "ttl must be a number"
      end
      if ALLOWED_TYPES.include?(params[:type])
        type = params[:type]
      else
        @errors << "Invalid Type"
      end
      if type == "MX"
        if params[:priority] =~ /^([0-9]+)$/
          address = "#{$1} #{address}"
        else
          @errors << "priority must be a number"
        end
      end
      unless @errors.empty?
        @error = "<ul class=\"errors\">" + @errors.collect { |e| "<li>#{e}</li>" }.join + "</ul>"
        r :zone, @zone.origin[0..-1]
      else
        create_record(z,name,type,ttl,address)
        redirect "/control/dns/#{@zone.key}"
      end
    end

  end
end

AWS::Admin.add_tab('dns','/control/dns')

__END__

@@ dns
- unless @zones.empty?
  %table
    %thead
      %tr
        %th Name
        %th Records
        %th Updated on
        %th Actions
    %tbody
      - @zones.each_value do |zone|
        %tr
          %th
            %a{ :href => "/control/dns/#{zone.key}" } #{zone.origin}
          %td #{zone.records.size}
          %td #{File.mtime(zone.filename)}
          %td
            %a{ :href => "/control/dns/#{zone.key}/delete", :onClick => POST, :title => "Delete Zone #{zone.origin}" } Delete
- else
  %p A sad day. You have no zones yet.
%h3 Create a Zone
%form.create{ :method => "post" }
  - if @error
    %span{ :style => "color:#cc0000" }= @error
  %div.required
    %label{ :for => "zone" } Zone
    %input{ :name => "zone", :type => "text", :value => "" }
  %input#newbucket{ :type => "submit", :value => "Create", :name => "newzone" }

@@ zone
%table
  %thead
    %tr
      %th Name
      %th TTL
      %th Type
      %th Value
      %th Actions
  %tbody
    - @zone.records.each do |record|
      - unless record.type == "SOA"
        %tr
          %th= record.name
          %td= record.ttl
          %td= record.type
          %td= record.address
          %td
            %a{ :href => "/control/dns/#{@zone.key}/delete?name=#{record.name}&type=#{record.type}&address=#{record.address}", :onClick => POST, :title => "Delete Record #{record.name} IN #{record.type} #{record.address}" } Delete
%h3 Add Record
%form.create{ :method => "post" }
  - if @error
    %span{ :style => "color:#cc0000" }= @error
  %div.required
    %label{ :for => "name" } Name
    %input{ :name => "name", :type => "text", :value => @zone.origin }
  %div.required
    %label{ :for => "type" } Type
    %select{ :name => "type", :onchange => "if (this.value == 'MX') { $('ttl_div').style.display = 'block' } else { $('ttl_div').style.display = 'none' }" }
      %option{} A
      %option{} AAAA
      %option{} CNAME
      %option{} MX
      %option{} NS
      %option{} TXT
      %option{} PTR
  %div.required{ :style => "float:left" }
    %label{ :for => "ttl" } TTL
    %input{ :name => "ttl", :type => "text", :value => @zone.ttl, :style => "width:7em" }
  %div.required{ :style => "float:left;margin-left:20px;display:none", :id => "ttl_div" }
    %label{ :for => "priority" } Priority
    %input{ :name => "priority", :type => "text", :value => "10", :style => "width:4em" }
  %div{ :style => "clear:both" }
  %div.required
    %label{ :for => "value" } Address/Value
    %input{ :name => "value", :type => "text", :value => "" }
  %input#newbucket{ :type => "submit", :value => "Create", :name => "newrecord" }
