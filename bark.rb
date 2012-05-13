#!/usr/bin/env ruby
require 'fileutils'
require 'set'
require 'yaml'
require 'digest/md5'


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


def copyAndMd5(source, target)
    sourceStat = File::stat(source)
    digest = Digest::MD5.new()
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


COPY_SIZE = 64 * 1024 * 1024

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

$targetMd5Path = File::join($targetPath, 'md5.txt')
$targetTempPath = File::join($targetPath, 'temp.copying')
$targetMd5UpdatePath = File::join($targetPath, 'md5-update.txt')
$targetMd5MergedPath = File::join($targetPath, 'md5-merged.txt')

$allSourceFiles = Set.new
$allSourceDirs = Set.new

$filesCopiedCount = 0
$filesCopiedSize = 0
$filesArchivedCount = 0

$targetMd5 = Hash.new
$targetSize = Hash.new
$targetMd5Reverse = Hash.new

FileUtils::mkdir($targetFilePath) unless File::directory?($targetFilePath)

if File::exists?($targetMd5Path)
    File::open($targetMd5Path, 'r') do |f|
        f.each_line do |line|
            next if line.strip.empty?
            md5 = line[0, 32]
            size = line[33, line.index(' ', 33) - 33].to_i
            path = line.strip[line.index(' ', 33) + 1, line.size]
            $targetMd5[path] = md5
            $targetMd5Reverse[md5] ||= Array.new
            $targetMd5Reverse[md5] << path
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
            md5 = copyAndMd5(path, destPath)
            if md5
                $targetMd5[relativePath] = md5
                $targetSize[relativePath] = File::size(destPath)
                $targetMd5Reverse[md5] ||= Array.new
                $targetMd5Reverse[md5] << relativePath
                $filesCopiedCount += 1
                $filesCopiedSize += File::size(path)
                File::open($targetMd5UpdatePath, 'a') do |f|
                    f.puts "#{md5} #{File::size(destPath)} #{relativePath}"
                    f.flush
                end
            end
        end
        $allSourceFiles << relativePath
    end
end

# remove MD5 codes for all files that are no more in target
md5PathsToBeRemoved = Array.new
$targetMd5.each_key do |path|
    unless File::exists?(File::join($targetFilePath, path))
        md5PathsToBeRemoved << path
    end
end

md5PathsToBeRemoved.each do |path|
    md5 = $targetMd5[path] 
    $targetMd5.delete(path)
    $targetSize.delete(path)
    $targetMd5Reverse[md5].delete(path)
    $targetMd5Reverse.delete(md5) if $targetMd5Reverse[md5].empty?
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
            # check whether the md5 can be found somewhere else in the target directory
            copyExists = false
            md5 = $targetMd5[relativePath]
            if md5
                otherFiles = $targetMd5Reverse[md5]
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

# remove MD5 codes for all files that are no more in target
md5PathsToBeRemoved = Array.new
$targetMd5.each_key do |path|
    unless File::exists?(File::join($targetFilePath, path))
        md5PathsToBeRemoved << path
    end
end

md5PathsToBeRemoved.each do |path|
    md5 = $targetMd5[path] 
    $targetMd5.delete(path)
    $targetSize.delete(path)
    if $targetMd5Reverse.include?(md5)
        $targetMd5Reverse[md5].delete(path)
        $targetMd5Reverse.delete(md5) if $targetMd5Reverse[md5].empty?
    end
end

# now update the MD5 cache: add all md5-update entries backwards,
# then add all previous md5 entries, every file once only

$mergedFiles = Set.new
$stdout.flush

print 'Updating MD5 cache... '
$stdout.flush
File::open($targetMd5MergedPath, 'w') do |fm|
    if File::exists?($targetMd5UpdatePath)
        File::open($targetMd5UpdatePath, 'r') do |fu|
            entries = fu.read.split("\n").reverse
            entries.each do |line|
                next if line.strip.empty?
                begin
                    md5 = line[0, 32]
                    size = line[33, line.index(' ', 33) - 33].to_i
                    path = line.strip[line.index(' ', 33) + 1, line.size]
                    if $targetMd5.include?(path) && (!$mergedFiles.include?(path))
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
        FileUtils::rm_f($targetMd5UpdatePath)
    end
    if File::exists?($targetMd5Path)
        File::open($targetMd5Path, 'r') do |f|
            entries = f.read.split("\n")
            entries.each do |line|
                next if line.strip.empty?
                md5 = line[0, 32]
                size = line[33, line.index(' ', 33) - 33].to_i
                path = line.strip[line.index(' ', 33) + 1, line.size]
                if $targetMd5.include?(path) && (!$mergedFiles.include?(path))
                    fm.puts line 
                    $mergedFiles << path
                end
            end
        end
        FileUtils::rm_f($targetMd5Path)
    end
end
FileUtils::mv($targetMd5MergedPath, $targetMd5Path)
puts 'done.'


puts "Backup finished successfully, #{$allSourceFiles.size} files in #{$allSourceDirs.size} directories up-to-date."
puts "Updated #{$filesCopiedCount} files (#{bytesToString($filesCopiedSize)})." if $filesCopiedCount > 0
puts "Archived #{$filesArchivedCount} files." if $filesArchivedCount > 0
