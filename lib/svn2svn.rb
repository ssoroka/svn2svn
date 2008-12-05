# 
# svn2svn
# 
# Replicates changesets from one SVN repository to another, includes diffs 
# and comments of each revision, but
# - Excludes svn property changes
# - Excludes revisions without file modifications (e.g. new directory)
#
# Since each revision of the source repository is checked out as r{\d+} sub 
# directories, the whole process may take hours, depending on connectivity.
#
# Works on unix only, with 'svn' and 'svnadmin' commandline tools. Written 
# and used on Ubuntu 5.10. Provided as-is and absolutely no warranty - aka 
# Don't bet your life on it
# 
# License: same as Subversion 
# http://subversion.tigris.org/project_license.html
#
# version 0.1; 14 May 2006; choonkeat at gmail dot com
#
class Svn2Svn
  @@temp_path = "temp_path" # the working directory for your new repository
  attr_accessor :src_url, :dest_url, :curr_revision, :comments,
    :start_revision, :end_revision

  # create with src svn url and (optional) destination svn url
  def initialize(src_url, dest_url = nil, start_revision=1, end_revision=nil)
    self.src_url = src_url
    self.start_revision = start_revision
    self.end_revision = end_revision
    self.comments = []
    revision = self.start_revision.to_i
    while (self.end_revision.nil? || revision <= end_revision.to_i) &&
      (File.exist?("r#{revision}") || svn("checkout #{self.src_url} -r #{revision} r#{revision}"))
      revision = revision + 1
    end
    self.end_revision = revision - 1
    puts "Last revision: #{self.end_revision}"

    # prep @@temp_path
    if dest_url.nil? or dest_url == ""
      # if dest_url isn't given, we create our own 
      # local svn repository and commit into it
      Svn2Svn.rmdirs "temp_svn" if File.exist?("temp_svn")
      system "svnadmin create temp_svn"
      IO.popen("pwd") do |f|
        dest_url = f.read.chomp
      end
      dest_url = File.join(dest_url, "temp_svn")
      self.dest_url = "file://#{dest_url}"
      puts "dest url = #{self.dest_url}"
      Svn2Svn.rmdirs @@temp_path if File.exist?(@@temp_path)
      svn "export r#{self.start_revision} #{@@temp_path}"
      svn "import #{@@temp_path} #{self.dest_url} -m 'import by svn2svn'"
      Svn2Svn.rmdirs @@temp_path
      svn "checkout #{self.dest_url} #{@@temp_path}"
    else
      self.dest_url = dest_url
      Svn2Svn.rmdirs @@temp_path if File.exist?(@@temp_path)
      svn "checkout #{self.dest_url} #{@@temp_path}"
      patch_commit(@@temp_path, "r#{self.start_revision}", @@temp_path, 
                   'first commit by svn2svn')
    end

  end

  # perform actual copying of data,
  # 1. retrieve comments
  # 2. loop through each revision and apply the diff onto our 'temp_path'
  # 3. commit with respective comment
  # 4. cleanup
  def copy
    get_comments
    revision = self.start_revision.to_i
    while revision < self.end_revision 
      # generate a diff between rX and rX+1 - but excluding changes
      # inside .svn. because even if there's a diff, we can't easily
      # patch it into @@temp_path's .svn. Hence, svn properties changes
      # won't be migrated
      comment = self.comments.pop
      patch_commit("r#{revision}", "r#{revision+1}", "#{@@temp_path}", comment)
      revision = revision + 1
    end
  end

  def patch_commit(older, newer, dest, comments)
    puts "#{older} > #{newer}"
    system "diff -Naur -x '\.svn' #{older} #{newer} | patch -p1 -d #{dest}"
    svn "status #{dest}" do |f|
      f.read.split(/\n/).each do |line|
        if line =~ /^\?\s+(.+)$/
          svn "add #{$1}"
        elsif line =~ /^\!\s+(.+)$/
          svn "delete #{$1}"
        elsif line =~ /^(A|M)\s+(.+)$/ # actually 'A' shouldn't happen
          puts "#{line}"               # unless previous commit failed
        else
          throw "unknown: #{line}"
        end
      end
    end
    svn "commit #{dest} -m '#{comments.to_s.gsub(/'/, '')}'"
  end

  class << self
    # recursively remove a directory and its content
    def rmdirs(path)
      Dir.entries(File.join(path)).each do |entry|
        if entry == "." or entry == ".."
        elsif File.file?(File.join(path, entry))
          File.unlink(File.join(path, entry))
        else
          rmdirs(path.to_a.dup << entry)
        end
      end
      Dir.rmdir(File.join(path))
    end
  end

  private 
  # get all comments (until self.end_revision)
  def get_comments
    self.comments = []
    IO.popen "svn log r#{self.end_revision}" do |f|
      revision = nil
      author_dt = nil
      data = ""
      range = (self.start_revision.to_i + 1)..self.end_revision.to_i
      f.read.split(/\n/).each do |line|
        if line =~ /^\-+$/
          if not revision.nil? and range.include?(revision.to_i)
            self.comments << "#{data.strip}\n#{author_dt}"
          end
          revision = nil
          author_dt = nil
          data = ""   
        elsif line =~ /^r(\d+) \| (.+) \|[^\|]+$/
          revision = $1
          author_dt = $2
          data = ""          
        else
          data = "#{data}\n#{line}"
        end
      end
    end
    puts "Fetched #{self.comments.size} comments."
    self.comments
  end

  # remove temp folders used to store each and every revision 
  def cleanup
    revision = 1
    while File.exist?("r#{revision}")
      Svn2Svn.rmdirs "r#{revision}"
      revision = revision + 1
    end
  end

  def svn(*commands)
    retval = true
    puts "\n> svn #{commands.join(' ')}\n"
    IO.popen("svn #{commands.join(' ')} 2>&1") do |f|
      if block_given?
        yield f
      else
        data = f.read
        if data =~ /svn: No such revision/
          retval = false
        elsif data =~ /svn: .+ failed/
          puts "Retrying... \n#{data.chomp}\n*******************\n\n"
          sleep 5
          retval = svn(*commands)
        elsif data =~ /Committed revision (\d+)\./
          self.curr_revision = $1.to_i
          puts "#{data.chomp}"
        else
          puts "#{data.chomp}"
        end
      end
    end
    retval
  end
end

if ARGV.size < 1 
  puts <<USAGE
Usage: [src_url] [dest_url = ''] [start_revision = 1] [end_revision = nil]

  Create a copy of repository from scratch (revisions number will be identical)
    e.g. http://server/source
    1. a SVN repository will be created at ./temp_svn
    2. revision 1 of http://server/source will be imported to ./temp_svn
    3. ./temp_svn will be checkout to ./temp_path
    4. and all revisions from http://server/source will be patched 
       and committed to ./temp_svn

  Append all changes from repository A to repository B
    e.g. http://server/source svn://newserver/target
    1. svn://newserver/target will be checked out to ./temp_path
    2. all revisions from http://server/source will be patched 
       and committed to ./temp_svn

  Append changes from repository A r45 onwards to repository B
    e.g. http://server/source svn://newserver/target 45
    1. svn://newserver/target will be checked out to ./temp_path
    2. revisions 45 onwards from http://server/source will be patched 
       and committed to ./temp_svn

  Append changes from repository A r45:r90 to repository B
    e.g. http://server/source svn://newserver/target 45 90
    1. svn://newserver/target will be checked out to ./temp_path
    2. revisions 45 to 90 from http://server/source will be patched 
       and committed to ./temp_svn
USAGE
else
  svn2svn = Svn2Svn.new(*ARGV)
  svn2svn.copy
end

