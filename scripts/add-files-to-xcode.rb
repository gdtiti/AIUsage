#!/usr/bin/env ruby
# 自动将新文件添加到 Xcode 项目
# 需要安装: gem install xcodeproj

require 'xcodeproj'

project_path = '/Users/sylearn/Desktop/AIUsage/AIUsage.xcodeproj'
project = Xcodeproj::Project.open(project_path)

# 获取主 target
target = project.targets.first

# 获取主 group
main_group = project.main_group['AIUsage']

# 要添加的文件
files_to_add = [
  { path: 'AIUsage/Models/ProxyConfiguration.swift', group: 'Models' },
  { path: 'AIUsage/ViewModels/ProxyViewModel.swift', group: 'ViewModels' },
  { path: 'AIUsage/Views/ProxyManagementView.swift', group: 'Views' },
  { path: 'AIUsage/Views/ProxyConfigEditorView.swift', group: 'Views' }
]

puts "正在添加文件到 Xcode 项目..."

files_to_add.each do |file_info|
  file_path = file_info[:path]
  group_name = file_info[:group]
  
  # 获取或创建 group
  group = main_group[group_name] || main_group.new_group(group_name)
  
  # 添加文件引用
  file_ref = group.new_file(file_path)
  
  # 添加到 build phase
  target.source_build_phase.add_file_reference(file_ref)
  
  puts "  ✓ 已添加: #{file_path}"
end

# 保存项目
project.save

puts ""
puts "✓ 所有文件已成功添加到 Xcode 项目！"
puts ""
puts "下一步："
puts "  1. 在 Xcode 中打开项目"
puts "  2. 按 Cmd+B 编译"
puts "  3. 按 Cmd+R 运行"
