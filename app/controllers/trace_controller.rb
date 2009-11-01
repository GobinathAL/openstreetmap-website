class TraceController < ApplicationController
  layout 'site'

  before_filter :authorize_web
  before_filter :set_locale
  before_filter :require_user, :only => [:mine, :create, :edit, :delete]
  before_filter :authorize, :only => [:api_details, :api_data, :api_create]
  before_filter :check_database_readable, :except => [:api_details, :api_data, :api_create]
  before_filter :check_database_writable, :only => [:create, :edit, :delete]
  before_filter :check_api_readable, :only => [:api_details, :api_data]
  before_filter :check_api_writable, :only => [:api_create]
  before_filter :require_allow_read_gpx, :only => [:api_details, :api_data]
  before_filter :require_allow_write_gpx, :only => [:api_create]
  around_filter :api_call_handle_error, :only => [:api_details, :api_data, :api_create]

  # Counts and selects pages of GPX traces for various criteria (by user, tags, public etc.).
  #  target_user - if set, specifies the user to fetch traces for.  if not set will fetch all traces
  def list(target_user = nil, action = "list")
    # from display name, pick up user id if one user's traces only
    display_name = params[:display_name]
    if target_user.nil? and !display_name.blank?
      target_user = User.find(:first, :conditions => [ "visible = ? and display_name = ?", true, display_name])
      if target_user.nil?
        @title = t'trace.no_such_user.title'
        @not_found_user = display_name
        render :action => 'no_such_user', :status => :not_found
        return
      end
    end

    # set title
    if target_user.nil?
      @title = t 'trace.list.public_traces'
    elsif @user and @user == target_user
      @title = t 'trace.list.your_traces'
    else
      @title = t 'trace.list.public_traces_from', :user => target_user.display_name
    end

    @title += t 'trace.list.tagged_with', :tags => params[:tag] if params[:tag]

    # four main cases:
    # 1 - all traces, logged in = all public traces + all user's (i.e + all mine)
    # 2 - all traces, not logged in = all public traces
    # 3 - user's traces, logged in as same user = all user's traces 
    # 4 - user's traces, not logged in as that user = all user's public traces
    if target_user.nil? # all traces
      if @user
        conditions = ["(gpx_files.visibility in ('public', 'identifiable') OR gpx_files.user_id = ?)", @user.id] #1
      else
        conditions  = ["gpx_files.visibility in ('public', 'identifiable')"] #2
      end
    else
      if @user and @user == target_user
        conditions = ["gpx_files.user_id = ?", @user.id] #3 (check vs user id, so no join + can't pick up non-public traces by changing name)
      else
        conditions = ["gpx_files.visibility in ('public', 'identifiable') AND gpx_files.user_id = ?", target_user.id] #4
      end
    end
    
    if params[:tag]
      @tag = params[:tag]

      files = Tracetag.find_all_by_tag(params[:tag]).collect { |tt| tt.gpx_id }

      if files.length > 0
        conditions[0] += " AND gpx_files.id IN (#{files.join(',')})"
      else
        conditions[0] += " AND 0 = 1"
      end
    end
    
    conditions[0] += " AND gpx_files.visible = ?"
    conditions << true

    @trace_pages, @traces = paginate(:traces,
                                     :include => [:user, :tags],
                                     :conditions => conditions,
                                     :order => "gpx_files.timestamp DESC",
                                     :per_page => 20)

    # put together SET of tags across traces, for related links
    tagset = Hash.new
    if @traces
      @traces.each do |trace|
        trace.tags.reload if params[:tag] # if searched by tag, ActiveRecord won't bring back other tags, so do explicitly here
        trace.tags.each do |tag|
          tagset[tag.tag] = tag.tag
        end
      end
    end
    
    # final helper vars for view
    @action = action
    @display_name = target_user.display_name if target_user
    @all_tags = tagset.values
  end

  def mine
    # Load the preference of whether the user set the trace public the last time
    @trace = Trace.new
    visibility = @user.preferences.find(:first, :conditions => {:k => "gps.trace.visibility"})
    if visibility
      @trace.visibility = visibility.v
    elsif @user.preferences.find(:first, :conditions => {:k => "gps.trace.public", :v => "default"}).nil?
      @trace.visibility = "private"
    else 
      @trace.visibility = "public"
    end
    list(@user, "mine")
  end

  def view
    @trace = Trace.find(params[:id])

    if @trace and @trace.visible? and
       (@trace.public? or @trace.user == @user)
      @title = t 'trace.view.title', :name => @trace.name
    else
      flash[:error] = t 'trace.view.trace_not_found'
      redirect_to :controller => 'trace', :action => 'list'
    end
  rescue ActiveRecord::RecordNotFound
    flash[:error] = t 'trace.view.trace_not_found'
    redirect_to :controller => 'trace', :action => 'list'
  end

  def create
    if params[:trace]
      logger.info(params[:trace][:gpx_file].class.name)
      if params[:trace][:gpx_file].respond_to?(:read)
        begin
          do_create(params[:trace][:gpx_file], params[:trace][:tagstring],
                    params[:trace][:description], params[:trace][:visibility])
        rescue
        end

        if @trace.id
          logger.info("id is #{@trace.id}")
          flash[:notice] = t 'trace.create.trace_uploaded'

          redirect_to :action => 'mine'
        end
      else
        @trace = Trace.new({:name => "Dummy",
                            :tagstring => params[:trace][:tagstring],
                            :description => params[:trace][:description],
                            :visibility => params[:trace][:visibility],
                            :inserted => false, :user => @user,
                            :timestamp => Time.now.getutc})
        @trace.valid?
        @trace.errors.add(:gpx_file, "can't be blank")
      end
    end
    @title = t 'trace.create.upload_trace'
  end

  def data
    trace = Trace.find(params[:id])

    if trace.visible? and (trace.public? or (@user and @user == trace.user))
      if request.format == Mime::XML
        send_file(trace.xml_file, :filename => "#{trace.id}.xml", :type => Mime::XML.to_s, :disposition => 'attachment')
      else
        send_file(trace.trace_name, :filename => "#{trace.id}#{trace.extension_name}", :type => trace.mime_type, :disposition => 'attachment')
      end
    else
      render :nothing => true, :status => :not_found
    end
  rescue ActiveRecord::RecordNotFound
    render :nothing => true, :status => :not_found
  end

  def edit
    @trace = Trace.find(params[:id])

    if @user and @trace.user == @user
      @title = t 'trace.edit.title', :name => @trace.name
      if params[:trace]
        @trace.description = params[:trace][:description]
        @trace.tagstring = params[:trace][:tagstring]
        @trace.visibility = params[:trace][:visibility]
        if @trace.save
          redirect_to :action => 'view'
        end        
      end
    else
      render :nothing => true, :status => :forbidden
    end
  rescue ActiveRecord::RecordNotFound
    render :nothing => true, :status => :not_found
  end

  def delete
    trace = Trace.find(params[:id])

    if @user and trace.user == @user
      if request.post? and trace.visible?
        trace.visible = false
        trace.save
        flash[:notice] = t 'trace.delete.scheduled_for_deletion'
        redirect_to :controller => 'traces', :action => 'mine'
      else
        render :nothing => true, :status => :bad_request
      end
    else
      render :nothing => true, :status => :forbidden
    end
  rescue ActiveRecord::RecordNotFound
    render :nothing => true, :status => :not_found
  end

  def georss
    conditions = ["gpx_files.visibility in ('public', 'identifiable')"]

    if params[:display_name]
      conditions[0] += " AND users.display_name = ?"
      conditions << params[:display_name]
    end

    if params[:tag]
      conditions[0] += " AND EXISTS (SELECT * FROM gpx_file_tags AS gft WHERE gft.gpx_id = gpx_files.id AND gft.tag = ?)"
      conditions << params[:tag]
    end

    traces = Trace.find(:all, :include => :user, :conditions => conditions, 
                        :order => "timestamp DESC", :limit => 20)

    rss = OSM::GeoRSS.new

    traces.each do |trace|
      rss.add(trace.latitude, trace.longitude, trace.name, trace.user.display_name, url_for({:controller => 'trace', :action => 'view', :id => trace.id, :display_name => trace.user.display_name}), "<img src='#{url_for({:controller => 'trace', :action => 'icon', :id => trace.id, :user_login => trace.user.display_name})}'> GPX file with #{trace.size} points from #{trace.user.display_name}", trace.timestamp)
    end

    render :text => rss.to_s, :content_type => "application/rss+xml"
  end

  def picture
    trace = Trace.find(params[:id])

    if trace.inserted?
      if trace.public? or (@user and @user == trace.user)
        expires_in 7.days, :private => !trace.public?, :public => trace.public?
        send_file(trace.large_picture_name, :filename => "#{trace.id}.gif", :type => 'image/gif', :disposition => 'inline')
      else
        render :nothing => true, :status => :forbidden
      end
    else
      render :nothing => true, :status => :not_found
    end
  rescue ActiveRecord::RecordNotFound
    render :nothing => true, :status => :not_found
  end

  def icon
    trace = Trace.find(params[:id])

    if trace.inserted?
      if trace.public? or (@user and @user == trace.user)
        expires_in 7.days, :private => !trace.public?, :public => trace.public?
        send_file(trace.icon_picture_name, :filename => "#{trace.id}_icon.gif", :type => 'image/gif', :disposition => 'inline')
      else
        render :nothing => true, :status => :forbidden
      end
    else
      render :nothing => true, :status => :not_found
    end
  rescue ActiveRecord::RecordNotFound
    render :nothing => true, :status => :not_found
  end

  def api_details
    trace = Trace.find(params[:id])

    if trace.public? or trace.user == @user
      render :text => trace.to_xml.to_s, :content_type => "text/xml"
    else
      render :nothing => true, :status => :forbidden
    end
  rescue ActiveRecord::RecordNotFound
    render :nothing => true, :status => :not_found
  end

  def api_data
    trace = Trace.find(params[:id])

    if trace.public? or trace.user == @user
      send_file(trace.trace_name, :filename => "#{trace.id}#{trace.extension_name}", :type => trace.mime_type, :disposition => 'attachment')
    else
      render :nothing => true, :status => :forbidden
    end
  rescue ActiveRecord::RecordNotFound
    render :nothing => true, :status => :not_found
  end

  def api_create
    if request.post?
      tags = params[:tags] || ""
      description = params[:description] || ""
      visibility = params[:visibility]

      if visibility.nil?
        if params[:public] && params[:public].to_i.nonzero?
          visibility = "public"
        else
          visibility = "private"
        end
      end

      if params[:file].respond_to?(:read)
        do_create(params[:file], tags, description, visibility)

        if @trace.id
          render :text => @trace.id.to_s, :content_type => "text/plain"
        elsif @trace.valid?
          render :nothing => true, :status => :internal_server_error
        else
          render :nothing => true, :status => :bad_request
        end
      else
        render :nothing => true, :status => :bad_request
      end
    else
      render :nothing => true, :status => :method_not_allowed
    end
  end

private

  def do_create(file, tags, description, visibility)
    # Sanitise the user's filename
    name = file.original_filename.gsub(/[^a-zA-Z0-9.]/, '_')

    # Get a temporary filename...
    filename = "/tmp/#{rand}"

    # ...and save the uploaded file to that location
    File.open(filename, "w") { |f| f.write(file.read) }

    # Create the trace object, falsely marked as already
    # inserted to stop the import daemon trying to load it
    @trace = Trace.new({
      :name => name,
      :tagstring => tags,
      :description => description,
      :visibility => visibility,
      :inserted => true,
      :user => @user,
      :timestamp => Time.now.getutc
    })

    Trace.transaction do
      begin
        # Save the trace object
        @trace.save!

        # Rename the temporary file to the final name
        FileUtils.mv(filename, @trace.trace_name)
      rescue Exception => ex
        # Remove the file as we have failed to update the database
        FileUtils.rm_f(filename)

        # Pass the exception on
        raise
      end

      begin
        # Clear the inserted flag to make the import daemon load the trace
        @trace.inserted = false
        @trace.save!
      rescue Exception => ex
        # Remove the file as we have failed to update the database
        FileUtils.rm_f(@trace.trace_name)

        # Pass the exception on
        raise
      end
    end

    # Finally save the user's preferred privacy level
    if pref = @user.preferences.find(:first, :conditions => {:k => "gps.trace.visibility"})
      pref.v = visibility
      pref.save
    else
      @user.preferences.create(:k => "gps.trace.visibility", :v => visibility)
    end
    
  end

end
