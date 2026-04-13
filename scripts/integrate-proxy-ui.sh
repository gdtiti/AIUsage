#!/bin/bash

# Claude Code Proxy UI - Xcode 项目集成脚本
# 此脚本会打开 Xcode 并提供添加文件的指导

set -e

echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║     Claude Code Proxy UI - Xcode 项目集成                            ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""

PROJECT_DIR="/Users/sylearn/Desktop/AIUsage"
XCODE_PROJECT="$PROJECT_DIR/AIUsage.xcodeproj"

# 检查文件是否存在
echo "✓ 检查新增文件..."
FILES=(
    "AIUsage/Models/ProxyConfiguration.swift"
    "AIUsage/ViewModels/ProxyViewModel.swift"
    "AIUsage/Views/ProxyManagementView.swift"
    "AIUsage/Views/ProxyConfigEditorView.swift"
)

for file in "${FILES[@]}"; do
    if [ -f "$PROJECT_DIR/$file" ]; then
        echo "  ✓ $file"
    else
        echo "  ✗ $file (缺失)"
        exit 1
    fi
done

echo ""
echo "✓ 所有文件已就绪！"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  方法 1: 使用 Xcode GUI（推荐）"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "1. 打开 Xcode 项目："
echo "   open '$XCODE_PROJECT'"
echo ""
echo "2. 在 Xcode 中添加文件："
echo ""
echo "   a) 右键点击 'AIUsage/Models' 文件夹"
echo "      → 选择 'Add Files to AIUsage...'"
echo "      → 选择 'ProxyConfiguration.swift'"
echo "      → 确保 'AIUsage' target 被选中"
echo "      → 点击 'Add'"
echo ""
echo "   b) 右键点击 'AIUsage/ViewModels' 文件夹"
echo "      → 选择 'Add Files to AIUsage...'"
echo "      → 选择 'ProxyViewModel.swift'"
echo "      → 确保 'AIUsage' target 被选中"
echo "      → 点击 'Add'"
echo ""
echo "   c) 右键点击 'AIUsage/Views' 文件夹"
echo "      → 选择 'Add Files to AIUsage...'"
echo "      → 选择 'ProxyManagementView.swift' 和 'ProxyConfigEditorView.swift'"
echo "      → 确保 'AIUsage' target 被选中"
echo "      → 点击 'Add'"
echo ""
echo "3. 编译项目："
echo "   按 Cmd+B 或点击 Product → Build"
echo ""
echo "4. 运行应用："
echo "   按 Cmd+R 或点击 Product → Run"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  方法 2: 使用命令行（实验性）"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "注意：由于 Xcode 项目文件格式复杂，建议使用方法 1"
echo ""
echo "如果你想尝试命令行方式，可以安装 xcodeproj gem："
echo "  gem install xcodeproj"
echo ""
echo "然后运行自动添加脚本（需要 Ruby）"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

read -p "是否现在打开 Xcode？(y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "正在打开 Xcode..."
    open "$XCODE_PROJECT"
    echo ""
    echo "✓ Xcode 已打开！请按照上述步骤添加文件。"
else
    echo "稍后可以手动打开 Xcode："
    echo "  open '$XCODE_PROJECT'"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  完成后的验证步骤"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "1. 在 Xcode 项目导航器中，确认以下文件已添加："
echo "   ✓ AIUsage/Models/ProxyConfiguration.swift"
echo "   ✓ AIUsage/ViewModels/ProxyViewModel.swift"
echo "   ✓ AIUsage/Views/ProxyManagementView.swift"
echo "   ✓ AIUsage/Views/ProxyConfigEditorView.swift"
echo ""
echo "2. 编译项目（Cmd+B），确保没有错误"
echo ""
echo "3. 运行应用（Cmd+R），在侧边栏中查看新的菜单项："
echo "   'Claude Code Proxy' / 'Claude Code 代理'"
echo ""
echo "4. 点击菜单项，应该能看到精美的代理管理界面"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📚 参考文档："
echo "  • docs/proxy-ui-quickstart.md - 快速启动指南"
echo "  • docs/proxy-ui-implementation.md - 详细实现文档"
echo "  • docs/PROXY_SUMMARY.md - 完整总结"
echo ""
echo "如有问题，请查看文档或检查 Xcode 控制台的错误信息。"
echo ""
