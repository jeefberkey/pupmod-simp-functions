Puppet::Type.type(:init_ulimit).provide(:sysv) do

  # TODO: Remove this when Puppet::Util::SELinux is fixed
  class SELinux_kludge
    include Puppet::Util::SELinux

    def replace_file(target, mode, &content)
      selinux_current_context = self.get_selinux_current_context(target)

      Puppet::Util.replace_file(target,mode,&content)

      self.set_selinux_context(target, selinux_current_context)
    end

  end

  def exists?
    # Super hack-fu
    determine_target
    # TODO: Finish refactoring all of this!

    @source_file = File.readlines("#{@target}")
    @warning_comment = "# Puppet-'#{resource[:item]}' Remove this line if removing the value below."

    # If we have the warning comment, assume that we've got the item.
    # This is mainly done so that we don't mess up any existing code by accident.
    @source_file.find do |line|
      line =~ /^#\s*Puppet-'#{resource[:item]}'/
    end
  end

  def create
    new_content = ""

    initial_comments = true
    wrote_content = false

    fh = File.open("#{@target}")

    @source_file.each do |line|
      if initial_comments then
        if line =~ /^\s*#/ then
          new_content << line
          next
        else
          initial_comments = false
        end
      elsif not wrote_content then
        new_content << "#{@warning_comment}\n"
        new_content << "#{ulimit_string}\n"
        wrote_content = true
      end

      new_content << line
    end

    SELinux_kludge.new.replace_file("#{@target}",0644) { |f| f.puts new_content }
  end

  def destroy
    new_content = ""

    skip_line = false
    @source_file.each do |line|

      # Skip the actual item.
      if skip_line and line =~ /^\s*ulimit -#{resource[:item]}/ then
        skip_line = false
        next
      end

      # Skip the comment
      if line =~ /^#\s*Puppet-'#{resource[:item]}'/ then
        skip_line = true
        next
      end

      new_content << line
    end

    SELinux_kludge.new.replace_file("#{@target}",0644) { |f| f.puts new_content }
  end

  def value
    retval = 'UNKNOWN'
    found_comment = false
    @source_file.each do |line|
      if found_comment then
        # This really shouldn't happen, but it's possible that someone might
        # stuff some empty lines in there or something.
        if line =~ /^\s*ulimit -#{resource[:item]} (.*)/ then
          retval = $1
          break
        else
          next
        end
      end
      if line =~ /^#\s*Puppet-'#{resource[:item]}'/ then
        found_comment = true
        next
      end
    end

    retval
  end

  def value=(should)
    new_content = @source_file.dup

    comment_line = @source_file.find_index{|x| x =~ /^#\s*Puppet-'#{resource[:item]}'/}
    ulimit_match = @source_file.find_index{|x| x =~ /^\s*ulimit -#{resource[:item]}/}

    if comment_line and not ulimit_match then
      # Someone deleted the ulimit, but not the comment!
      new_content.insert(comment_line+1,ulimit_string)

    elsif ulimit_match < comment_line then
      # Well, this is a bit of a mess, delete the comment and insert above the
      # ulimit
      new_content.delete_at[comment_line]
      new_content.insert(ulimit_match,@warning_comment)
    else
      # Get rid of the current ulimit and replace it with the new one.
      new_content[ulimit_match] = ulimit_string
    end

    SELinux_kludge.new.replace_file("#{@target}",0644) { |f| f.puts new_content }

  end

  private

  # Builds the ulimit string to write out to the file.
  def ulimit_string
    toret = 'ulimit'

    if resource[:limit_type] != 'both' then
      toret << " -#{resource[:limit_type][0].chr.upcase}"
    end

    toret << " -#{resource[:item]} #{resource[:value]}\n"
  end

  def determine_target
    @provider = :redhat
    @target = @resource[:target]

    if @target[0].chr != '/' then
      @provider = @resource.catalog.resources.find{ |r|
        r.is_a?(Puppet::Type.type(:service)) and r[:name] =~ /^#{@resource[:target]}(\.service)?$/
      }[:provider]

      case @provider
        when :systemd
          svc_name = "#{@target}.service" unless @target =~ /\.service$/

          systemd_target = nil
          Find.find('/etc/systemd/system') do |path|
            next if not File.file?(path)

            if File.basename(path) == svc_name then
              systemd_target = path
              break
            end
          end

          raise(Puppet::ParseError,"Could not find a systemd service for #{svc_name}") unless systemd_target

          @target = systemd_target
        when :upstart
          raise(Puppet::ParseError,'The init_ulimit type cannot modify upstart scripts!')
        else
          # Default to good ol' /etc/init.d
          @target = "/etc/init.d/#{@target}"

          raise(Puppet::ParseError,"File '#{@target}' not found.") unless File.exist?(@target)
      end
    end
  end
end
