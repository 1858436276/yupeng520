# User Instruction Memory

This file records user instructions, preferences, and teachings for reference in future interactions.

## Format

### User Instruction Entry
User instruction entries should follow this format:

[User Instruction Summary]
- Date: [YYYY-MM-DD]
- Context: [Mentioned scenario or time]
- Instructions:
  - [Content of user teaching or instruction, described line by line]

### Project Knowledge Entry
Entries discovered by the Agent during task execution should follow this format:

[Project Knowledge Summary]
- Date: [YYYY-MM-DD]
- Context: Discovered by Agent while performing [specific task description]
- Category: [Operations & Deployment|Build Methods|Testing Methods|Troubleshooting & Debugging|Workflow & Collaboration|Environment Configuration]
- Instructions:
  - [Specific knowledge points, described line by line]

## Deduplication Strategy
- Before adding a new entry, check for similar or identical instructions.
- If a duplicate is found, skip the new entry or merge it with the existing one.
- When merging, update the context or date information.
- This helps avoid redundant entries and keeps the memory file tidy.

## Entries

[Project Knowledge Summary]
- Date: 2026-08-17
- Context: Discovered by Agent while fixing "悬浮球点击无法进入播放页" issue in cloudreve4_flutter
- Category: Troubleshooting & Debugging
- Instructions:
  - 全局悬浮层（MiniMusicPlayerOverlay 音频球、MiniVideoWindow 视频小窗）挂在 main.dart 的 MaterialApp builder 的 Stack 中，与 Navigator 平级，`Navigator.of(context)` 找不到 Navigator 会静默失败；导航必须用 `AppUpdateService.navigatorKey.currentState.push()`

[Project Knowledge Summary]
- Date: 2026-08-17
- Context: Discovered by Agent while building cloudreve4_flutter
- Category: Build Methods
- Instructions:
  - 本地无 Flutter/Dart SDK，编译验证通过 GitHub Actions 的 build.yml workflow 完成：`gh workflow run build.yml`，约 25 分钟/次
  - 提交后查询 `gh run view <run-id> --json status,conclusion`，失败用 `gh run view <run-id> --log-failed` 查看日志
