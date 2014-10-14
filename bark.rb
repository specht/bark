#!/usr/bin/env ruby
require 'fileutils'
require 'set'
require 'yaml'
require 'digest/sha1'


def bytesToString(ai_Size)
    if ai_Size < 1024
        return "#{ai_Size} bytes"
    elsif ai_Size < 1024 * 1024
        return "#{sprintf('%1.2f', ai_Size.to_f / 1024.0)} KiB"
    elsif ai_Size < 1024 * 1024 * 1024
        return "#{sprintf('%1.2f', ai_Size.to_f / 1024.0 / 1024.0)} MiB"
    elsif ai_Size < 1024 * 1024 * 1024 * 1024
        return "#{sprintf('%1.2f', ai_Size.to_f / 1024.0 / 1024.0 / 1024.0)} GiB"
    end
    return "#{sprintf('%1.2f', ai_Size.to_f / 1024.0 / 1024.0 / 1024.0 / 1024.0)} TiB"
end


def copyAndSha1(source, target)
    sourceStat = File::stat(source)
    digest = Digest::SHA1.new()
    File::open($targetTempPath, 'w') do |ft|
        size = File::size(source)
        begin
            fs = File::open(source, 'r')
        rescue
            puts "Skipping #{source}, access denied."
            FileUtils::rm_r($targetTempPath)
            return nil
        end
        
        while !fs.eof?
            block = fs.read(COPY_SIZE)
            digest << block
            ft.write(block)
        end
        
        fs.close
    end
    File::utime(File::atime(source), File::mtime(source), $targetTempPath)
    File::chmod(sourceStat.mode, $targetTempPath)
    FileUtils::mv($targetTempPath, target)
    return digest.hexdigest
end


def iterateFiles(argDir, yieldFirst, &block)
    # find all entries
    files = Dir.glob(File::join(argDir, '*'), File::FNM_DOTMATCH)
    
    # remove this and parent directory
    files.reject! do |x|
        ['.', '..'].include?(x[argDir.size + 1, x.size])
    end
    
    files.sort! do |a, b|
        ad = File::directory?(a) ? 1 : 0
        bd = File::directory?(b) ? 1 : 0
        (ad == bd) ? ( a <=> b ) : (ad <=> bd)
    end
    
    # iterate and yield, recurse if directory
    files.each do |path|
        next if File::symlink?(path)
        next if File::pipe?(path)
        relativePath = path[$sourcePath.size + 1, path.size]
        skip = false
        $config['excludeList'].each do |x|
            if File.fnmatch(x, relativePath)
                skip = true
                break
            end
        end
        next if skip
        yield(path) if yieldFirst
        iterateFiles(path, yieldFirst, &block) if File::directory?(path)
        yield(path) unless yieldFirst
    end
end


COPY_SIZE = 4 * 1024 * 1024

$allConfig = YAML::load_file("bark.conf.yaml")

if ARGV.empty?
    puts "Usage: ruby bark.rb [scope] [--init]"
    exit 1
end

scope = ARGV.first

unless $allConfig.include?(scope)
    puts "Error: Unknown backup scope '#{scope}'."
    exit 1
end

$config = $allConfig[scope]
$config['excludeList'] ||= Array.new

$sourcePath = $config['sourcePath']
$targetPath = $config['targetPath']

# remove trailing slash
$sourcePath = $sourcePath[0, $sourcePath.size - 1] if $sourcePath[-1, 1] == '/'
$targetPath = $targetPath[0, $targetPath.size - 1] if $targetPath[-1, 1] == '/'

unless File::directory?($sourcePath)
    puts "Error: Source directory does not exist."
    exit(1)
end

unless File::directory?($targetPath)
    puts "Error: Target directory does not exist."
    exit(1)
end

$targetMarkerPath = File::join($targetPath, 'bark.yaml')

if ARGV[1] == '--init'
    puts "Initializing the target directory as a bark target..."
    # find all entries
    files = Dir.glob(File::join($targetPath, '*'), File::FNM_DOTMATCH)
    
    # remove this and parent directory
    files.reject! do |x|
        ['.', '..', 'lost+found'].include?(x[$targetPath.size + 1, x.size])
    end
    
    unless files.empty?
        puts "Error: Target directory is not empty."
        exit(1)
    end
    
    File::open($targetMarkerPath, 'w') do |f|
        info = Hash.new
        info['source'] = $sourcePath
        f.puts info.to_yaml
    end
    puts 'done.'
    exit
end

unless File::exists?($targetMarkerPath)
    puts "Error: The target directory has not been set up as a bark target."
    puts "Please run the script with the --init argument."
    exit(1)
end

# check bark.yaml
test = YAML::load_file($targetMarkerPath)
if (test['source'] != $sourcePath)
    puts "This does not seem right, exiting..."
    exit 1
end

$targetFilePath = File::join($targetPath, 'mirror')
$targetArchivePath = File::join($targetPath, 'archive')

$targetSha1Path = File::join($targetPath, 'sha1.txt')
$targetTempPath = File::join($targetPath, 'temp.copying')
$targetSha1UpdatePath = File::join($targetPath, 'sha1-update.txt')
$targetSha1MergedPath = File::join($targetPath, 'sha1-merged.txt')

$allSourceFiles = Set.new
$allSourceDirs = Set.new

$filesCopiedCount = 0
$filesCopiedSize = 0
$filesArchivedCount = 0

$targetSha1 = Hash.new
$targetSize = Hash.new
$targetSha1Reverse = Hash.new

FileUtils::mkdir($targetFilePath) unless File::directory?($targetFilePath)

if File::exists?($targetSha1Path)
    File::open($targetSha1Path, 'r') do |f|
        f.each_line do |line|
            next if line.strip.empty?
            sha1 = line[0, 40]
            size = line[41, line.index(' ', 41) - 41].to_i
            path = line.strip[line.index(' ', 41) + 1, line.size]
            $targetSha1[path] = sha1
            $targetSha1Reverse[sha1] ||= Array.new
            $targetSha1Reverse[sha1] << path
        end
    end
end

# copy all changed files to target path
iterateFiles($sourcePath, true) do |path|
    if File::directory?(path)
        # we have a directory, create it and recurse
        relativePath = path[$sourcePath.size + 1, path.size]
        destPath = File::join($targetFilePath, relativePath)
        $allSourceDirs << relativePath
        FileUtils::mkdir(destPath) unless File::directory?(destPath)
    else
        # we have a file
        size = File::size(path)
        time = File::mtime(path)
        relativePath = path[$sourcePath.size + 1, path.size]
        destPath = File::join($targetFilePath, relativePath)
        copyThis = (!File::exists?(destPath)) || 
                (File::size(path) != File::size(destPath)) || 
                (File::mtime(path) != File::mtime(destPath))
        if copyThis
            puts "Updating #{relativePath}"
            sha1 = copyAndSha1(path, destPath)
            if sha1
                $targetSha1[relativePath] = sha1
                $targetSize[relativePath] = File::size(destPath)
                $targetSha1Reverse[sha1] ||= Array.new
                $targetSha1Reverse[sha1] << relativePath
                $filesCopiedCount += 1
                $filesCopiedSize += File::size(path)
                File::open($targetSha1UpdatePath, 'a') do |f|
                    f.puts "#{sha1} #{File::size(destPath)} #{relativePath}"
                    f.flush
                end
            end
        end
        $allSourceFiles << relativePath
    end
end

# remove SHA1 codes for all files that are no more in target
sha1PathsToBeRemoved = Array.new
$targetSha1.each_key do |path|
    unless File::exists?(File::join($targetFilePath, path))
        sha1PathsToBeRemoved << path
    end
end

sha1PathsToBeRemoved.each do |path|
    sha1 = $targetSha1[path] 
    $targetSha1.delete(path)
    $targetSize.delete(path)
    $targetSha1Reverse[sha1].delete(path)
    $targetSha1Reverse.delete(sha1) if $targetSha1Reverse[sha1].empty?
end

# see which files are in target, but no more in source
# copy all changed files to target path
iterateFiles($targetFilePath, false) do |path|
    if File::directory?(path)
        relativePath = path[$targetFilePath.size + 1, path.size]
        unless $allSourceDirs.include?(relativePath)
            # remove directory, it should be empty by now
            FileUtils::rmdir(path)
        end
    else
        relativePath = path[$targetFilePath.size + 1, path.size]
        unless $allSourceFiles.include?(relativePath)
            # check whether the sha1 can be found somewhere else in the target directory
            copyExists = false
            sha1 = $targetSha1[relativePath]
            if sha1
                otherFiles = $targetSha1Reverse[sha1]
                if otherFiles
                    otherFiles.reject! { |x| x == relativePath }
                    unless otherFiles.empty?
                        renamedPath = otherFiles.first
                        oldFileSize = File::size(path)
                        newPath = File::join($targetFilePath, renamedPath)
                        newFileSize = File::size(newPath)
                        if (oldFileSize == newFileSize)
                            copyExists = true
                            FileUtils::rm(path)
                        end
                    end
                end
            end
            unless copyExists
                puts "Archiving #{relativePath}"
                $filesArchivedCount += 1
                FileUtils::mkpath(File::join($targetArchivePath, File::dirname(relativePath)))
                FileUtils::mv(File::join($targetFilePath, relativePath),
                              File::join($targetArchivePath, relativePath))
            end
        end
    end
end

# remove SHA1 codes for all files that are no more in target
sha1PathsToBeRemoved = Array.new
$targetSha1.each_key do |path|
    unless File::exists?(File::join($targetFilePath, path))
        sha1PathsToBeRemoved << path
    end
end

sha1PathsToBeRemoved.each do |path|
    sha1 = $targetSha1[path] 
    $targetSha1.delete(path)
    $targetSize.delete(path)
    if $targetSha1Reverse.include?(sha1)
        $targetSha1Reverse[sha1].delete(path)
        $targetSha1Reverse.delete(sha1) if $targetSha1Reverse[sha1].empty?
    end
end

# now update the SHA1 cache: add all sha1-update entries backwards,
# then add all previous sha1 entries, every file once only

$mergedFiles = Set.new
$stdout.flush

print 'Updating SHA1 cache... '
$stdout.flush
File::open($targetSha1MergedPath, 'w') do |fm|
    if File::exists?($targetSha1UpdatePath)
        File::open($targetSha1UpdatePath, 'r') do |fu|
            entries = fu.read.split("\n").reverse
            entries.each do |line|
                next if line.strip.empty?
                begin
                    sha1 = line[0, 40]
                    size = line[41, line.index(' ', 41) - 41].to_i
                    path = line.strip[line.index(' ', 41) + 1, line.size]
                    if $targetSha1.include?(path) && (!$mergedFiles.include?(path))
                        fm.puts line 
                        $mergedFiles << path
                    end
                rescue
                    puts "AAAH! ERROR IN LINE:"
                    puts line
                    exit 100
                end
            end
        end
        FileUtils::rm_f($targetSha1UpdatePath)
    end
    if File::exists?($targetSha1Path)
        File::open($targetSha1Path, 'r') do |f|
            entries = f.read.split("\n")
            entries.each do |line|
                next if line.strip.empty?
                sha1 = line[0, 40]
                size = line[41, line.index(' ', 41) - 41].to_i
                path = line.strip[line.index(' ', 41) + 1, line.size]
                if $targetSha1.include?(path) && (!$mergedFiles.include?(path))
                    fm.puts line 
                    $mergedFiles << path
                end
            end
        end
        FileUtils::rm_f($targetSha1Path)
    end
end
FileUtils::mv($targetSha1MergedPath, $targetSha1Path)
puts 'done.'


puts "Backup finished successfully, #{$allSourceFiles.size} files in #{$allSourceDirs.size} directories up-to-date."
puts "Updated #{$filesCopiedCount} files (#{bytesToString($filesCopiedSize)})." if $filesCopiedCount > 0
puts "Archived #{$filesArchivedCount} files." if $filesArchivedCount > 0
