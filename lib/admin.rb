module AWS

  class Admin < Sinatra::Base

    ALLOWED_TYPES = ['A','AAAA','CNAME','MX','NS','PTR','TXT','SRV']

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

      delete_zone(z)
      redirect '/control/dns'
    end

    get %r{^\/dns\/(\w+)$} do
      login_required
      z, @zone = get_zone_by_key(params[:captures].first)
      r :zone, z[0..-2]
    end

    post %r{^\/dns\/(\w+)$} do
      login_required
      z, @zone = get_zone_by_key(params[:captures].first)
      records = []
      dont_save = false
      @zone.records.each { |r| records << r if r.type == "SOA" }
      @zone = @zone.clone

      params['records'].each do |type,list|
        list.each do |key,value|
          unless value[:name].empty? && value[:address].empty?
            record = DNSServer::ZoneFileRecord.new(value.merge({ :type => type, :class => "IN" }),@zone)
            dont_save = true unless record.errors.empty?
            records << record
          end
        end
      end
      @zone.records = records.sort { |x,y| "#{DNSServer::ZoneFile::SORT_ORDER[x.type] || 9}#{x.name}" <=> "#{DNSServer::ZoneFile::SORT_ORDER[y.type] || 9}#{y.name}" }

      if dont_save
        @error = "<ul class=\"errors\"><li>One or more records is invalid.</li></ul>"
        r :zone, z[0..-2]
      else
        DNSServer.zonemap[z] = @zone
        @zone.save()
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
%form.create{ :method => "post" }
  - unused_types = @zone.origin =~ /ARPA.$/i ? ['PTR'] : ALLOWED_TYPES.clone
  - unused_types.delete('PTR') if @zone.origin !~ /ARPA.$/i
  - if @error
    = preserve @error
  - @zone.get_record_groups.each do |records|
    - unused_types.delete(records.first.type)
    - unless records.first.type == "SOA"
      %h4= records.first.type
      %table.noborder{ :style => "margin-bottom:1em" }
        %thead
          %tr
            %th{ :style => "width:11em" } Name
            %th TTL
            - if records.first.type == "MX" || records.first.type == "SRV"
              %th Priority
            - if records.first.type == "SRV"
              %th Wt.
              %th Port
            %th{ :style => "width:11em" } Value
            %th{ :style => "width:3em" } 
        %tbody
          - count = 0
          - records.each do |record|
            %tr{ :style => record.errors.empty? ? "" : "background-color:#cc0000" }
              %td
                %input{ :name => "records[#{record.type}][#{count}][name]", :type => "text", :value => record.name }
              %td
                %input{ :name => "records[#{record.type}][#{count}][ttl]", :type => "text", :value => record.ttl, :style => "width:6em" }
              - if record.type == "MX" || record.type == "SRV"
                %td
                  %input{ :name => "records[#{record.type}][#{count}][priority]", :type => "text", :value => record.priority, :style => "width:4em" }
              - if record.type == "SRV"
                %td
                  %input{ :name => "records[#{record.type}][#{count}][weight]", :type => "text", :value => record.weight, :style => "width:3em" }
                %td
                  %input{ :name => "records[#{record.type}][#{count}][port]", :type => "text", :value => record.port, :style => "width:4em" }
              %td
                %input{ :name => "records[#{record.type}][#{count}][address]", :type => "text", :value => record.address }
              %td{ :align => "center" }
                %a{ :href => "javascript:///", :onclick => "this.parentNode.parentNode.remove();" }
                  %img{ :src => "/control/delete.png", :text => "Delete #{record.name} IN #{record.type} #{record.address}", :border => 0 }
            - count += 1
          %tr
            %td
              %input{ :name => "records[#{records.first.type}][#{count}][name]", :type => "text", :value => "" }
            %td
              %input{ :name => "records[#{records.first.type}][#{count}][ttl]", :type => "text", :value => "", :style => "width:6em" }
            - if records.first.type == "MX" || records.first.type == "SRV"
              %td
                %input{ :name => "records[#{records.first.type}][#{count}][priority]", :type => "text", :value => "", :style => "width:4em" }
            - if records.first.type == "SRV"
              %td
                %input{ :name => "records[#{records.first.type}][#{count}][weight]", :type => "text", :value => "", :style => "width:3em" }
              %td
                %input{ :name => "records[#{records.first.type}][#{count}][port]", :type => "text", :value => "", :style => "width:4em" }
            %td
              %input{ :name => "records[#{records.first.type}][#{count}][address]", :type => "text", :value => "" }
            %td
              %a{ :href => "javascript:///", :onclick => "addRow(this,#{count});" }
                %img{ :src => "/control/add.png", :text => "", :border => 0 }
  - unused_types.each do |type|
    %h4= type
    %table.noborder{ :style => "margin-bottom:1em" }
      %thead
        %tr
          %th{ :style => "width:11em" } Name
          %th TTL
          - if type == "MX" || type == "SRV"
            %th Priority
          - if type == "SRV"
            %th Wt.
            %th Port
          %th{ :style => "width:11em" } Value
          %th{ :style => "width:3em" } 
      %tbody
        %tr
          %td
            %input{ :name => "records[#{type}][0][name]", :type => "text", :value => "" }
          %td
            %input{ :name => "records[#{type}][0][ttl]", :type => "text", :value => "", :style => "width:6em" }
          - if type == "MX" || type == "SRV"
            %td
              %input{ :name => "records[#{type}][0][priority]", :type => "text", :value => "", :style => "width:4em" }
          - if type == "SRV"
            %td
              %input{ :name => "records[#{type}][0][weight]", :type => "text", :value => "", :style => "width:3em" }
            %td
              %input{ :name => "records[#{type}][0][port]", :type => "text", :value => "", :style => "width:4em" }
          %td
            %input{ :name => "records[#{type}][0][address]", :type => "text", :value => "" }
          %td
            %a{ :href => "javascript:///", :onclick => "addRow(this,0);" }
              %img{ :src => "/control/add.png", :text => "", :border => 0 }
 
  %input#updatezone{ :type => "submit", :value => "Update Zone", :name => "updatezone" }
:javascript
  function addRow(obj,row_count)
  {
    new_row = obj.parentNode.parentNode.cloneNode(true);
    ele = new_row.getElementsByTagName("input")
    for (var i = 0; i < ele.length; i++)
    {
      ele[i].name = ele[i].name.replace(row_count,row_count+1);
      ele[i].value = null;
    }
   
    obj.innerHTML = "<img src=\"/control/delete.png\" border=\"0\" /";
    obj.onclick = function() { this.parentNode.parentNode.remove(); }
    tbody = obj.parentNode.parentNode.parentNode;
    tbody.appendChild(new_row);
  }
